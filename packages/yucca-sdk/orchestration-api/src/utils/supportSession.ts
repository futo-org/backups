import type { ChildProcess } from 'node:child_process';
import { createInterface } from 'node:readline';
import type { Writable } from 'node:stream';
import { LoggingRepository } from '../repositories/logging.repository.js';
import type { SupportLogLine, SupportLogShipper } from './supportLogShipper.js';
import type { Redactor } from './supportRedaction.js';

export const SUPPORT_MODE_VERBOSITY = 2;

const DEFAULT_MAX_LOCAL_BUFFER_BYTES = 16 * 1024 * 1024;

export type SupportStream = {
  sessionId: string;
  shipper: SupportLogShipper;
  redact?: Redactor;
};

export class SupportSession {
  readonly verbosity = SUPPORT_MODE_VERBOSITY;

  private readonly logger = LoggingRepository.create(SupportSession.name);
  private localFailed = false;
  private localDroppedLines = 0;

  constructor(
    private readonly local: Writable,
    private readonly stream?: SupportStream,
    private readonly maxLocalBufferBytes = DEFAULT_MAX_LOCAL_BUFFER_BYTES,
  ) {
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
      this.stream.shipper.push(this.stream.redact ? { ...line, message: this.stream.redact(line.message) } : line);
    }
  }

  private recordLocally(line: SupportLogLine) {
    if (this.localFailed) {
      this.localDroppedLines++;
      return;
    }

    if (this.local.writableLength > this.maxLocalBufferBytes) {
      this.localDroppedLines++;
      return;
    }

    this.local.write(JSON.stringify(line) + '\n');
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

  private endLocal() {
    if (this.localFailed || this.local.destroyed) {
      return Promise.resolve();
    }

    return new Promise<void>((done) => this.local.end(() => done()));
  }
}
