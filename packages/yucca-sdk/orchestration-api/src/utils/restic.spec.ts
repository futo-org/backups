import type { BackupMessage } from '@futo-org/restic-wrapper';
import { jest } from '@jest/globals';
import { createSampledLogWriter } from './restic.js';

describe(createSampledLogWriter.name, () => {
  it('leaves per-file verbose events to the support log', () => {
    const log = jest.fn();
    const write = createSampledLogWriter<BackupMessage>(log);

    for (let index = 0; index < 1000; index++) {
      write({ message_type: 'verbose_status', action: 'unchanged', item: `/photos/${index}.jpg` } as BackupMessage);
    }
    write({ message_type: 'summary', files_new: 0 } as BackupMessage);

    expect(log).toHaveBeenCalledTimes(1);
    expect(log).toHaveBeenCalledWith(expect.objectContaining({ message_type: 'summary' }));
  });
});
