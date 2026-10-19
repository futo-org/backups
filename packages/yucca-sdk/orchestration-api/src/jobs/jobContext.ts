import type { BackupMessage, ErrorMessage, ForgetMessage, RestoreMessage } from '@futo-org/restic-wrapper';
import { type WriteStream } from 'node:fs';

export type JobLogEvent = BackupMessage | RestoreMessage | ErrorMessage | ForgetMessage;

export class JobContext {
  constructor(
    readonly signal: AbortSignal,
    readonly logWriter: WriteStream,
  ) {}

  log(event: JobLogEvent) {
    this.logWriter.write(JSON.stringify(event) + '\n');
  }
}
