import type { BackupMessage, ErrorMessage, ForgetMessage, RestoreMessage } from '@futo-org/restic-wrapper';
import { type Writable } from 'node:stream';
import { isDeepStrictEqual } from 'node:util';
import { type JobOutcomeDto, type JobProgressDto } from '../dto/job.dto.js';
import { easeRemaining, holdPublishedEnd, type ShownEstimate } from '../utils/endEstimate.js';
import { getBytesPerMs, sampleUploadRate, startUploadRate, type UploadRate } from '../utils/uploadRate.js';

export type JobLogEvent = BackupMessage | RestoreMessage | ErrorMessage | ForgetMessage;

type StatusMessage<T> = Extract<T, { message_type: 'status' }>;
type ResticStatus = StatusMessage<BackupMessage> & Partial<StatusMessage<RestoreMessage>>;

export class JobContext {
  readonly outcome: JobOutcomeDto = { errors: [] };
  progress?: JobProgressDto;

  private scanFinished = false;
  private rate?: UploadRate;
  private shown?: ShownEstimate;

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
        const status: ResticStatus = event;
        const bytesDone = status.bytes_done ?? status.bytes_restored;

        this.scanFinished ||= status.seconds_remaining !== undefined || status.bytes_restored !== undefined;

        const progress = {
          percentDone: Math.min(status.percent_done, 1),
          scanning: !this.scanFinished,
          estimatedEndAt: this.estimateEnd(bytesDone, status.total_bytes),
          bytesDone,
          totalBytes: status.total_bytes,
          currentFiles: status.current_files ?? [],
        };

        if (!isDeepStrictEqual(progress, this.progress)) {
          this.progress = progress;
        }

        break;
      }
      case 'summary': {
        this.progress = {
          ...this.progress,
          percentDone: 1,
          scanning: false,
          estimatedEndAt: undefined,
          currentFiles: [],
        };

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

  private estimateEnd(bytesDone: number | undefined, totalBytes: number | undefined) {
    const now = Date.now();
    if (bytesDone === undefined || totalBytes === undefined || !this.scanFinished) {
      this.rate = undefined;
      this.shown = undefined;
      return;
    }

    if (!this.rate || bytesDone < this.rate.lastBytes) {
      this.rate = startUploadRate(bytesDone, now);
      this.shown = undefined;
      return;
    }

    this.rate = sampleUploadRate(this.rate, bytesDone, now);
    const bytesPerMs = getBytesPerMs(this.rate);
    if (bytesPerMs === undefined) {
      return this.progress?.estimatedEndAt;
    }

    this.shown = easeRemaining(this.shown, Math.max(totalBytes - bytesDone, 0) / bytesPerMs, now);
    return holdPublishedEnd(this.progress?.estimatedEndAt, this.shown);
  }
}
