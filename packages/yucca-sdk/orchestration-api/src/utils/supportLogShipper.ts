import { promisify } from 'node:util';
import { gzip } from 'node:zlib';
import { LoggingRepository } from '../repositories/logging.repository.js';

const gzipAsync = promisify(gzip);

export type SupportLogLine = {
  time: string;
  stream: 'stdout' | 'stderr' | 'meta';
  command: string;
  message: string;
};

export type SupportLogCredentials = { token: string; expiresAt: Date };

export type SupportLogEndpoint = {
  url: string;
  credentials: SupportLogCredentials;
  refresh: () => Promise<SupportLogCredentials>;
};

export type SupportLogShipperOptions = {
  maxBufferBytes: number;
  batchBytes: number;
  flushIntervalMs: number;
  maxAttempts: number;
  finishTimeoutMs: number;
};

const DEFAULT_OPTIONS: SupportLogShipperOptions = {
  maxBufferBytes: 64 * 1024 * 1024,
  batchBytes: 4 * 1024 * 1024,
  flushIntervalMs: 2000,
  maxAttempts: 8,
  finishTimeoutMs: 30_000,
};

const REFRESH_MARGIN_MS = 10 * 60 * 1000;
const REQUEST_TIMEOUT_MS = 60_000;
const MAX_BACKOFF_MS = 30_000;

type Batch = { lines: string[]; bytes: number };

class PermanentError extends Error {}

export class SupportLogShipper {
  private readonly logger = LoggingRepository.create(SupportLogShipper.name);
  private readonly options: SupportLogShipperOptions;

  private current: Batch = { lines: [], bytes: 0 };
  private sealed: Batch[] = [];
  private bufferedBytes = 0;
  private droppedSinceLastBatch = 0;
  private seq = 0;
  private draining?: Promise<void>;
  private timer?: NodeJS.Timeout;
  private stopped = false;

  droppedLines = 0;

  constructor(
    private readonly endpoint: SupportLogEndpoint,
    options: Partial<SupportLogShipperOptions> = {},
  ) {
    this.options = { ...DEFAULT_OPTIONS, ...options };
    this.timer = setInterval(() => this.seal(), this.options.flushIntervalMs);
    this.timer.unref();
  }

  push(line: SupportLogLine) {
    const json = JSON.stringify(line);
    if (this.stopped || this.bufferedBytes + json.length > this.options.maxBufferBytes) {
      this.drop(1);
      return;
    }

    this.current.lines.push(json);
    this.current.bytes += json.length + 1;
    this.bufferedBytes += json.length + 1;

    if (this.current.bytes >= this.options.batchBytes) {
      this.seal();
    }
  }

  async finish() {
    clearInterval(this.timer);
    this.seal();

    const deadline = new Promise<void>((resolve) => setTimeout(resolve, this.options.finishTimeoutMs).unref());
    await Promise.race([this.drain(true), deadline]);

    this.stopped = true;
    this.drop(this.sealed.reduce((total, batch) => total + batch.lines.length, 0));
    this.sealed = [];
  }

  private drop(lines: number) {
    this.droppedLines += lines;
    this.droppedSinceLastBatch += lines;
  }

  private seal() {
    if (this.current.lines.length > 0) {
      this.sealed.push(this.current);
      this.current = { lines: [], bytes: 0 };
    }

    if (!this.draining && this.sealed.length > 0) {
      void this.drain(false);
    }
  }

  private drain(final: boolean): Promise<void> {
    const previous = this.draining ?? Promise.resolve();
    const tracked: Promise<void> = previous
      .then(() => this.sendSealed(final))
      .finally(() => {
        if (this.draining !== tracked) {
          return;
        }

        this.draining = undefined;
        if (this.sealed.length > 0 && !this.stopped) {
          void this.drain(false);
        }
      });
    this.draining = tracked;
    return tracked;
  }

  private async sendSealed(final: boolean) {
    let finalSent = false;
    while (this.sealed.length > 0 && !this.stopped) {
      const batch = this.sealed.shift()!;
      this.bufferedBytes -= batch.bytes;
      const isLast = final && this.sealed.length === 0;
      finalSent = (await this.send(batch, isLast)) && isLast;
    }

    if (final && !this.stopped) {
      if (!finalSent) {
        await this.send({ lines: [], bytes: 0 }, true);
      }
      this.stopped = true;
    }
  }

  private async send(batch: Batch, final: boolean): Promise<boolean> {
    const dropped = this.droppedSinceLastBatch;
    this.droppedSinceLastBatch = 0;
    const seq = this.seq++;
    const body = await gzipAsync(batch.lines.length > 0 ? batch.lines.join('\n') + '\n' : '');

    for (let attempt = 1; attempt <= this.options.maxAttempts; attempt++) {
      try {
        await this.post(body, seq, dropped, final);
        return true;
      } catch (error) {
        if (error instanceof PermanentError || attempt === this.options.maxAttempts) {
          this.logger.warn(`Dropping support log batch ${seq} (${batch.lines.length} lines)`, error);
          this.drop(batch.lines.length);
          this.droppedSinceLastBatch += dropped;
          return false;
        }
        await new Promise((resolve) => setTimeout(resolve, Math.min(MAX_BACKOFF_MS, 1000 * 2 ** (attempt - 1))));
      }
    }

    return false;
  }

  private async post(body: Buffer, seq: number, dropped: number, final: boolean) {
    const { token } = await this.credentials();
    const response = await fetch(this.endpoint.url, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/x-ndjson',
        'content-encoding': 'gzip',
        'x-batch-seq': String(seq),
        'x-dropped-lines': String(dropped),
        ...(final && { 'x-batch-final': 'true' }),
      },
      body: new Uint8Array(body),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });

    if (response.ok) {
      return;
    }

    if (response.status === 401) {
      this.endpoint.credentials = { ...this.endpoint.credentials, expiresAt: new Date(0) };
      throw new Error('Support log token was rejected');
    }

    if (response.status >= 400 && response.status < 500) {
      throw new PermanentError(`Support log batch rejected with HTTP ${response.status}`);
    }

    throw new Error(`Support log batch failed with HTTP ${response.status}`);
  }

  private async credentials() {
    if (this.endpoint.credentials.expiresAt.getTime() - Date.now() > REFRESH_MARGIN_MS) {
      return this.endpoint.credentials;
    }

    try {
      this.endpoint.credentials = await this.endpoint.refresh();
    } catch (error) {
      this.stopped = true;
      throw new PermanentError('Support log session can no longer be refreshed', { cause: error });
    }

    return this.endpoint.credentials;
  }
}
