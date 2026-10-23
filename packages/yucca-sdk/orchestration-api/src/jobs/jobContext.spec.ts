import type { WriteStream } from 'node:fs';
import { JobContext, type JobLogEvent } from './jobContext.js';

describe(JobContext.name, () => {
  it('finishes progress and clears files and remaining time when the backup summary arrives', () => {
    const context = new JobContext(new AbortController().signal, { write: () => true } as unknown as WriteStream);

    context.log({
      message_type: 'status',
      percent_done: 0.4,
      seconds_remaining: 30,
      bytes_done: 40,
      total_bytes: 100,
      current_files: ['/data/a'],
    } as JobLogEvent);
    context.log({
      message_type: 'summary',
      files_new: 1,
      files_changed: 0,
      total_files_processed: 1,
      total_bytes_processed: 100,
      snapshot_id: 'abc',
    } as JobLogEvent);

    expect(context.progress).toMatchObject({ percentDone: 1, currentFiles: [], totalBytes: 100 });
    expect(context.progress?.secondsRemaining).toBeUndefined();
  });
});
