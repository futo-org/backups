import type { ChildProcess } from 'node:child_process';
import { createInterface } from 'node:readline';
import type { Writable } from 'node:stream';
import type { SupportLogLine, SupportLogShipper } from './supportLogShipper.js';
import type { Redactor } from './supportRedaction.js';

export const SUPPORT_MODE_VERBOSITY = 2;

export type SupportStream = {
  sessionId: string;
  shipper: SupportLogShipper;
  redact?: Redactor;
};

export class SupportSession {
  readonly verbosity = SUPPORT_MODE_VERBOSITY;

  constructor(
    private readonly local: Writable,
    private readonly stream?: SupportStream,
  ) {}

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
    this.local.write(JSON.stringify(line) + '\n');

    if (this.stream) {
      this.stream.shipper.push(this.stream.redact ? { ...line, message: this.stream.redact(line.message) } : line);
    }
  }

  async finish() {
    await this.stream?.shipper.finish();
    await new Promise<void>((done) => this.local.end(done));

    return { sessionId: this.stream?.sessionId, droppedLines: this.stream?.shipper.droppedLines ?? 0 };
  }
}
