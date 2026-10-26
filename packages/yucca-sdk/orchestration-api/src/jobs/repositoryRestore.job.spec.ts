import { jest } from '@jest/globals';
import type { WriteStream } from 'node:fs';
import { newResticRepositoryMock } from '../../test/mocks.js';
import { JobContext } from './jobContext.js';
import { RepositoryRestoreJob } from './repositoryRestore.job.js';

describe(RepositoryRestoreJob.name, () => {
  const resticParameters = {
    endpoint: 'rest:https://example.com/repository',
    key: new Uint8Array([1, 2, 3]),
    placement: { siteCode: null, storageClusterCode: null },
  };

  const makeJob = () => {
    const repositoryService = {
      getResticParameters: jest.fn<() => Promise<typeof resticParameters>>().mockResolvedValue(resticParameters),
    };
    const restic = newResticRepositoryMock();
    const telemetry = { submitStructuredLog: jest.fn() };
    const context = new JobContext(new AbortController().signal, {} as WriteStream);

    return {
      job: new RepositoryRestoreJob(repositoryService as never, restic as never, telemetry as never),
      restic,
      context,
    };
  };

  it('restores the snapshot with the requested options into the job log', async () => {
    const { job, restic, context } = makeJob();
    const options = { include: ['/photos'] };

    await job.run({ repositoryId: 'repository-1', snapshotId: 'snapshot-1', options }, context);

    expect(restic.restore).toHaveBeenCalledWith(
      resticParameters.endpoint,
      resticParameters.key,
      resticParameters.placement,
      'snapshot-1',
      options,
      expect.any(Function),
      context.signal,
    );
  });

  it('rethrows a failed restore', async () => {
    const { job, restic, context } = makeJob();
    restic.restore.mockRejectedValue(new Error('restic restore failed'));

    await expect(
      job.run({ repositoryId: 'repository-1', snapshotId: 'snapshot-1', options: {} }, context),
    ).rejects.toThrow('restic restore failed');
  });
});
