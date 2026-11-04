import type { ChildProcess } from 'node:child_process';
import { once } from 'node:events';
import { createInterface } from 'node:readline';
import type { Writable } from 'node:stream';
import { LoggingRepository } from '../repositories/logging.repository.js';
import type { SupportLogLine, SupportLogShipper } from './supportLogShipper.js';
import type { Redactor } from './supportRedaction.js';

export const SUPPORT_MODE_VERBOSITY = 2;

const DEFAULT_MAX_LOCAL_BUFFER_BYTES = 16 * 1024 * 1024;
const DEFAULT_LOCAL_FINISH_TIMEOUT_MS = 30_000;
const LOCAL_DESTROY_GRACE_MS = 1000;

const noop = () => {};

const UNCHANGED_ITEM_PREFIX = '{"message_type":"verbose_status","action":"unchanged"';

export type SupportSessionOptions = { maxLocalBufferBytes: number; localFinishTimeoutMs: number };

export type SupportStream = {
  sessionId: string;
  shipper: SupportLogShipper;
  redact?: Redactor;
};

export class SupportSession {
  readonly verbosity = SUPPORT_MODE_VERBOSITY;

  private readonly logger = LoggingRepository.create(SupportSession.name);
  private readonly options: SupportSessionOptions;
  private localFailed = false;
  private localDroppedLines = 0;
  private localPendingLines = 0;
  private localAbandoned = false;

  constructor(
    private readonly local: Writable,
    private readonly stream?: SupportStream,
    options: Partial<SupportSessionOptions> = {},
  ) {
    this.options = {
      maxLocalBufferBytes: DEFAULT_MAX_LOCAL_BUFFER_BYTES,
      localFinishTimeoutMs: DEFAULT_LOCAL_FINISH_TIMEOUT_MS,
      ...options,
    };

    local.on('error', (error) => {
      if (!this.localFailed) {
        this.localFailed = true;
        this.logger.warn('The local support log can no longer be written, recording continues without it', error);
      }
    });
  }

  get sessionId() {
    return this.stream?.sessionId;
  }

  attach(child: ChildProcess, command: string) {
    for (const [name, source] of [
      ['stdout', child.stdout],
      ['stderr', child.stderr],
    ] as const) {
      if (source) {
        createInterface({ input: source, crlfDelay: Infinity }).on('line', (message) =>
          this.record({ time: new Date().toISOString(), stream: name, command, message }),
        );
      }
    }
  }

  private record(line: SupportLogLine) {
    this.recordLocally(line);

    if (this.stream) {
      const expendable = line.stream === 'stdout' && line.message.startsWith(UNCHANGED_ITEM_PREFIX);
      this.stream.shipper.push(this.stream.redact ? { ...line, message: this.stream.redact(line.message) } : line, {
        expendable,
      });
    }
  }

  private recordLocally(line: SupportLogLine) {
    if (this.localFailed) {
      this.localDroppedLines++;
      return;
    }

    if (this.local.writableLength > this.options.maxLocalBufferBytes) {
      this.localDroppedLines++;
      return;
    }

    this.localPendingLines++;
    this.local.write(JSON.stringify(line) + '\n', (error) => {
      if (this.localAbandoned) {
        return;
      }

      this.localPendingLines--;
      if (error) {
        this.localDroppedLines++;
      }
    });
  }

  async finish() {
    await this.stream?.shipper.finish();
    await this.endLocal();

    return {
      sessionId: this.stream?.sessionId,
      droppedLines: this.stream?.shipper.droppedLines ?? 0,
      localDroppedLines: this.localDroppedLines,
    };
  }

  private async endLocal() {
    const closed = this.local.closed ? Promise.resolve() : once(this.local, 'close').then(noop, noop);
    if (!this.local.destroyed) {
      this.local.end();
    }

    if ((await this.within(closed, this.options.localFinishTimeoutMs)) === 'timeout') {
      this.logger.warn('The local support log did not finish writing in time, discarding what is still queued');
      this.abandonLocal();
      await this.within(closed, LOCAL_DESTROY_GRACE_MS);
    }
  }

  private abandonLocal() {
    this.localAbandoned = true;
    this.localDroppedLines += this.localPendingLines;
    this.localPendingLines = 0;
    this.local.destroy();
  }

  private within(promise: Promise<void>, ms: number) {
    return Promise.race([
      promise.then(() => 'done' as const),
      new Promise<'timeout'>((resolve) => setTimeout(() => resolve('timeout'), ms).unref()),
    ]);
  }
}
