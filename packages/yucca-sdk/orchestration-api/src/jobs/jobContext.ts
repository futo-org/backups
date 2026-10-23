import type { BackupMessage, ErrorMessage, ForgetMessage, RestoreMessage } from '@futo-org/restic-wrapper';
import { type Writable } from 'node:stream';
import { type JobOutcomeDto, type JobProgressDto } from '../dto/job.dto.js';

export type JobLogEvent = BackupMessage | RestoreMessage | ErrorMessage | ForgetMessage;

export class JobContext {
  readonly outcome: JobOutcomeDto = { errors: [] };
  progress?: JobProgressDto;

  constructor(
    readonly signal: AbortSignal,
    readonly logWriter: Writable,
  ) {}

  log(event: JobLogEvent) {
    this.logWriter.write(JSON.stringify(event) + '\n');

    if (Array.isArray(event)) {
      this.outcome.summary = {
        type: 'prune',
        kept: event.reduce((total, { keep }) => total + (keep?.length ?? 0), 0),
        removed: event.reduce((total, { remove }) => total + (remove?.length ?? 0), 0),
      };
      return;
    }

    switch (event.message_type) {
      case 'status': {
        const status: {
          percent_done: number;
          seconds_remaining?: number;
          bytes_done?: number;
          bytes_restored?: number;
          total_bytes?: number;
          current_files?: string[];
        } = event;
        this.progress = {
          percentDone: status.percent_done,
          secondsRemaining: status.seconds_remaining,
          bytesDone: status.bytes_done ?? status.bytes_restored,
          totalBytes: status.total_bytes,
          currentFiles: status.current_files ?? [],
        };
        break;
      }
      case 'summary': {
        this.progress = { ...this.progress, percentDone: 1, secondsRemaining: undefined, currentFiles: [] };
        this.outcome.summary ??=
          'files_new' in event
            ? {
                type: 'backup',
                filesNew: event.files_new,
                filesChanged: event.files_changed,
                totalFilesProcessed: event.total_files_processed,
                totalBytesProcessed: event.total_bytes_processed,
                snapshotId: event.snapshot_id,
              }
            : {
                type: 'restore',
                filesRestored: event.files_restored ?? 0,
                filesSkipped: event.files_skipped ?? 0,
                bytesRestored: event.bytes_restored ?? 0,
              };
        break;
      }
      case 'error': {
        const message = event.error?.message ?? event.message ?? 'Unknown error';
        this.outcome.errors.push(event.item ? `${event.item}: ${message}` : message);
        break;
      }
      case 'exit_error': {
        this.outcome.errors.push(`restic exited with code ${event.code}: ${event.message}`);
        break;
      }
      case 'raw': {
        this.outcome.errors.push(event.message);
        break;
      }
    }
  }
}
