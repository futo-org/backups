import { jest } from '@jest/globals';
import type { WriteStream } from 'node:fs';
import { newResticRepositoryMock } from '../../test/mocks.js';
import { JobName } from '../enum.js';
import { JobContext } from './jobContext.js';
import { RepositoryPruneJob } from './repositoryPrune.job.js';

describe(RepositoryPruneJob.name, () => {
  const resticParameters = {
    endpoint: 'rest:https://example.com/repository',
    key: new Uint8Array([1, 2, 3]),
    placement: { siteCode: null, storageClusterCode: null },
  };
  const retentionPolicy = { keepDaily: 7 };

  const makeJob = (policy: object | null = retentionPolicy) => {
    const repositoryService = {
      getResticParameters: jest.fn<() => Promise<typeof resticParameters>>().mockResolvedValue(resticParameters),
    };
    const repositories = {
      get: jest
        .fn<() => Promise<object | undefined>>()
        .mockResolvedValue({ id: 'repository-1', retentionPolicy: policy }),
    };
    const restic = newResticRepositoryMock();
    const jobs = { queue: jest.fn() };
    const telemetry = { submitStructuredLog: jest.fn() };
    const lines: string[] = [];
    const logWriter = { write: (line: string) => lines.push(line) } as unknown as WriteStream;
    const context = new JobContext(new AbortController().signal, logWriter);

    return {
      job: new RepositoryPruneJob(
        repositoryService as never,
        repositories as never,
        restic as never,
        jobs as never,
        telemetry as never,
      ),
      restic,
      jobs,
      lines,
      context,
    };
  };

  it('forgets by the retention policy, then prunes', async () => {
    const { job, restic, context } = makeJob();

    await job.run({ repositoryId: 'repository-1' }, context);

    expect(restic.forgetByPolicy).toHaveBeenCalledWith(
      resticParameters.endpoint,
      resticParameters.key,
      resticParameters.placement,
      retentionPolicy,
      context.signal,
    );
    expect(restic.prune).toHaveBeenCalledWith(
      resticParameters.endpoint,
      resticParameters.key,
      resticParameters.placement,
      context.signal,
    );
  });

  it('logs which snapshots were kept and removed', async () => {
    const { job, restic, lines, context } = makeJob();
    restic.forgetByPolicy.mockResolvedValue([
      {
        keep: [{ id: 'kept-1', time: '2026-10-12T00:00:00Z' }],
        remove: [{ id: 'removed-1', time: '2026-01-01T00:00:00Z' }],
        reasons: [{ snapshot: { id: 'kept-1' }, matches: ['daily snapshot'] }],
      },
    ] as never);

    await job.run({ repositoryId: 'repository-1' }, context);

    expect(lines.map((line) => JSON.parse(line))).toEqual([
      { message_type: 'yucca_prune_kept', id: 'kept-1', time: '2026-10-12T00:00:00Z', matches: ['daily snapshot'] },
      { message_type: 'yucca_prune_removed', id: 'removed-1', time: '2026-01-01T00:00:00Z' },
    ]);
  });

  it('queues a metrics sync even when the prune fails', async () => {
    const { job, restic, jobs, context } = makeJob();
    restic.prune.mockRejectedValue(new Error('restic prune failed'));

    await expect(job.run({ repositoryId: 'repository-1' }, context)).rejects.toThrow('restic prune failed');
    expect(jobs.queue).toHaveBeenCalledWith({
      name: JobName.RepositorySyncMetrics,
      data: { repositoryId: 'repository-1' },
    });
  });

  it('fails without a retention policy', async () => {
    const { job, restic, context } = makeJob(null);

    await expect(job.run({ repositoryId: 'repository-1' }, context)).rejects.toThrow(
      'No retention policy configured for this repository',
    );
    expect(restic.forgetByPolicy).not.toHaveBeenCalled();
  });
});
