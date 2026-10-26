import { jest } from '@jest/globals';
import type { WriteStream } from 'node:fs';
import { newResticRepositoryMock } from '../../test/mocks.js';
import { JobName } from '../enum.js';
import { JobContext } from './jobContext.js';
import { RepositorySnapshotForgetJob } from './repositorySnapshotForget.job.js';

describe(RepositorySnapshotForgetJob.name, () => {
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
    const jobs = { queue: jest.fn() };
    const telemetry = { submitStructuredLog: jest.fn() };
    const context = new JobContext(new AbortController().signal, {} as WriteStream);

    return {
      job: new RepositorySnapshotForgetJob(
        repositoryService as never,
        restic as never,
        jobs as never,
        telemetry as never,
      ),
      jobs,
      restic,
      context,
    };
  };

  it('forgets the snapshot and prunes', async () => {
    const { job, restic, context } = makeJob();

    await job.run({ repositoryId: 'repository-1', snapshotId: 'snapshot-1' }, context);

    expect(restic.forget).toHaveBeenCalledWith(
      resticParameters.endpoint,
      resticParameters.key,
      resticParameters.placement,
      'snapshot-1',
      true,
      context.signal,
    );
  });

  it('queues a metrics sync after forgetting', async () => {
    const { job, jobs, context } = makeJob();

    await job.run({ repositoryId: 'repository-1', snapshotId: 'snapshot-1' }, context);

    expect(jobs.queue).toHaveBeenCalledWith({
      name: JobName.RepositorySyncMetrics,
      data: { repositoryId: 'repository-1' },
    });
  });

  it('rethrows a failed forget without queueing a metrics sync', async () => {
    const { job, restic, jobs, context } = makeJob();
    restic.forget.mockRejectedValue(new Error('restic forget failed'));

    await expect(job.run({ repositoryId: 'repository-1', snapshotId: 'snapshot-1' }, context)).rejects.toThrow(
      'restic forget failed',
    );
    expect(jobs.queue).not.toHaveBeenCalled();
  });
});
