import { jest } from '@jest/globals';
import { PassThrough } from 'node:stream';
import { newResticRepositoryMock } from '../../test/mocks.js';
import { TaskCancelledError } from '../utils/errors.js';
import { JobContext } from './jobContext.js';
import { RepositoryBackupJob } from './repositoryBackup.job.js';

describe(RepositoryBackupJob.name, () => {
  const resticParameters = {
    endpoint: 'rest:https://example.com/repository',
    key: new Uint8Array([1, 2, 3]),
    placement: { siteCode: null, storageClusterCode: null },
  };

  const makeJob = (lastSnapshotId?: string, signal = new AbortController().signal) => {
    const repositoryService = {
      getBackendOrThrow: jest.fn<() => Promise<object>>().mockResolvedValue({
        backend: { isMetricsCapable: () => false },
      }),
      getResticParameters: jest.fn<() => Promise<typeof resticParameters>>().mockResolvedValue(resticParameters),
      updateLocalMetrics: jest.fn<() => Promise<void>>().mockResolvedValue(),
    };
    const repositories = {
      get: jest.fn<() => Promise<object>>().mockResolvedValue({
        id: 'repository-1',
        backendId: 'backend-1',
        remoteId: 'remote-1',
        retentionPolicy: null,
      }),
    };
    const repositoryPaths = { get: jest.fn<() => Promise<string[]>>().mockResolvedValue(['/data']) };
    const immichIntegration = { get: jest.fn<() => Promise<undefined>>().mockResolvedValue(undefined) };
    const moduleConfig = { get: () => ({}) };
    const restic = newResticRepositoryMock();
    const jobs = {
      queue: jest.fn(),
      getLastSnapshotId: jest.fn<() => Promise<string | undefined>>().mockResolvedValue(lastSnapshotId),
    };
    const telemetry = { submitStructuredLog: jest.fn() };
    const context = new JobContext(signal, new PassThrough());

    return {
      job: new RepositoryBackupJob(
        repositoryService as never,
        repositories as never,
        repositoryPaths as never,
        immichIntegration as never,
        moduleConfig as never,
        restic as never,
        jobs as never,
        telemetry as never,
      ),
      restic,
      context,
    };
  };

  it('passes the snapshot of the previous backup as the parent while it still exists', async () => {
    const { job, restic, context } = makeJob('snapshot-1');
    restic.snapshot.mockResolvedValue([{ id: 'snapshot-1' }] as never);

    await job.run({ repositoryId: 'repository-1' }, context);

    expect(restic.snapshot).toHaveBeenCalledWith(
      resticParameters.endpoint,
      resticParameters.key,
      resticParameters.placement,
      'snapshot-1',
      context.signal,
    );
    expect(restic.backup.mock.calls[0][7]).toBe('snapshot-1');
  });

  it('leaves the parent to restic when the previous snapshot no longer exists', async () => {
    const { job, restic, context } = makeJob('snapshot-1');
    restic.snapshot.mockResolvedValue([]);

    await job.run({ repositoryId: 'repository-1' }, context);

    expect(restic.backup.mock.calls[0][7]).toBeUndefined();
  });

  it('still backs up when the previous snapshot cannot be looked up', async () => {
    const { job, restic, context } = makeJob('snapshot-1');
    restic.snapshot.mockRejectedValue(new Error('repository unreachable'));

    await job.run({ repositoryId: 'repository-1' }, context);

    expect(restic.backup).toHaveBeenCalledTimes(1);
    expect(restic.backup.mock.calls[0][7]).toBeUndefined();
  });

  it('stops without backing up when cancelled during the parent lookup', async () => {
    const controller = new AbortController();
    const { job, restic, context } = makeJob('snapshot-1', controller.signal);
    const lookupStarted = Promise.withResolvers<void>();
    restic.snapshot.mockImplementation(
      (...args: unknown[]) =>
        new Promise((_, reject) => {
          const signal = args[4] as AbortSignal;
          signal.addEventListener('abort', () => reject(new Error('restic was killed')), { once: true });
          lookupStarted.resolve();
        }) as never,
    );

    const run = job.run({ repositoryId: 'repository-1' }, context);
    await lookupStarted.promise;
    controller.abort(new TaskCancelledError());

    await expect(run).rejects.toBeInstanceOf(TaskCancelledError);
    expect(restic.backup).not.toHaveBeenCalled();
  });

  it('does not look for a parent before the first backup', async () => {
    const { job, restic, context } = makeJob();

    await job.run({ repositoryId: 'repository-1' }, context);

    expect(restic.snapshot).not.toHaveBeenCalled();
    expect(restic.backup.mock.calls[0][7]).toBeUndefined();
  });
});
