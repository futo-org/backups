import { jest } from '@jest/globals';
import { PassThrough } from 'node:stream';
import { newImmichHooksMock, newResticRepositoryMock } from '../../test/mocks.js';
import { ResticTagPrefix } from '../enum.js';
import { TaskCancelledError, TaskWarningsError } from '../utils/errors.js';
import { JobContext } from './jobContext.js';
import { RepositoryBackupJob } from './repositoryBackup.job.js';

const makeImmichWal = () => ({
  isEnabledFor: jest.fn<() => Promise<boolean>>().mockResolvedValue(true),
  backupBaseIfDue: jest.fn<() => Promise<object | undefined>>().mockResolvedValue(undefined),
  prepareSnapshot: jest.fn<() => Promise<string>>().mockResolvedValue('0/3000060'),
});

describe(RepositoryBackupJob.name, () => {
  const resticParameters = {
    endpoint: 'rest:https://example.com/repository',
    key: new Uint8Array([1, 2, 3]),
    placement: { siteCode: null, storageClusterCode: null },
  };

  const makeJob = (
    lastSnapshotId?: string,
    signal = new AbortController().signal,
    lastTotalBytes?: number,
    immichWal?: object,
  ) => {
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
    const immichIntegration = { get: jest.fn<() => Promise<object>>().mockResolvedValue({ id: 'repository-1' }) };
    const moduleConfig = { get: () => ({ immichIntegration: { hooks: newImmichHooksMock() } }) };
    const restic = newResticRepositoryMock();
    const jobs = {
      queue: jest.fn(),
      getLastBackup: jest
        .fn<() => Promise<{ snapshotId: string; totalBytes?: number } | undefined>>()
        .mockResolvedValue(lastSnapshotId ? { snapshotId: lastSnapshotId, totalBytes: lastTotalBytes } : undefined),
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
        (immichWal ?? { isEnabledFor: jest.fn<() => Promise<boolean>>().mockResolvedValue(false) }) as never,
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

  it('expects the size of the previous backup so restic can skip its scan', async () => {
    const { job, restic, context } = makeJob('snapshot-1', undefined, 5_000_000);
    restic.snapshot.mockResolvedValue([{ id: 'snapshot-1' }] as never);
    const expectTotalBytes = jest.spyOn(context, 'expectTotalBytes');

    await job.run({ repositoryId: 'repository-1' }, context);

    expect(expectTotalBytes).toHaveBeenCalledWith(5_000_000);
    expect(restic.backup.mock.calls[0][8]).toBe(true);
  });

  it('lets restic scan when the previous backup recorded no size', async () => {
    const { job, restic, context } = makeJob('snapshot-1');
    restic.snapshot.mockResolvedValue([{ id: 'snapshot-1' }] as never);
    const expectTotalBytes = jest.spyOn(context, 'expectTotalBytes');

    await job.run({ repositoryId: 'repository-1' }, context);

    expect(expectTotalBytes).not.toHaveBeenCalled();
    expect(restic.backup.mock.calls[0][8]).toBe(false);
  });

  it('lets restic scan when the previous backup was empty', async () => {
    const { job, restic, context } = makeJob('snapshot-1', undefined, 0);
    restic.snapshot.mockResolvedValue([{ id: 'snapshot-1' }] as never);
    const expectTotalBytes = jest.spyOn(context, 'expectTotalBytes');

    await job.run({ repositoryId: 'repository-1' }, context);

    expect(expectTotalBytes).not.toHaveBeenCalled();
    expect(restic.backup.mock.calls[0][8]).toBe(false);
  });

  it('leaves the parent to restic when the previous snapshot no longer exists', async () => {
    const { job, restic, context } = makeJob('snapshot-1', undefined, 5_000_000);
    restic.snapshot.mockResolvedValue([]);

    await job.run({ repositoryId: 'repository-1' }, context);

    expect(restic.backup.mock.calls[0][7]).toBeUndefined();
    expect(restic.backup.mock.calls[0][8]).toBe(false);
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

  describe('with Immich WAL archiving', () => {
    it('tags the snapshot with the LSN archived before the file walk', async () => {
      const immichWal = makeImmichWal();
      const { job, restic, context } = makeJob(undefined, undefined, undefined, immichWal);
      restic.backup.mockImplementation(() => {
        expect(immichWal.prepareSnapshot).toHaveBeenCalled();
        return Promise.resolve({} as never);
      });

      await job.run({ repositoryId: 'repository-1' }, context);

      expect(immichWal.backupBaseIfDue).toHaveBeenCalledWith(context.signal);
      expect(restic.backup.mock.calls[0][6]).toEqual([
        `${ResticTagPrefix.ImmichBackupFileName}=dump.sql.gz`,
        `${ResticTagPrefix.ImmichWalLsn}=0/3000060`,
      ]);
    });

    it('still backs up the files with a warning when the WAL cannot be archived', async () => {
      const immichWal = makeImmichWal();
      immichWal.prepareSnapshot.mockRejectedValue(new Error('slot missing'));
      const { job, restic, context } = makeJob(undefined, undefined, undefined, immichWal);

      await expect(job.run({ repositoryId: 'repository-1' }, context)).rejects.toBeInstanceOf(TaskWarningsError);

      expect(restic.backup).toHaveBeenCalledTimes(1);
      expect(restic.backup.mock.calls[0][6]).toEqual([`${ResticTagPrefix.ImmichBackupFileName}=dump.sql.gz`]);
    });

    it('leaves the dump flow alone when WAL archiving is off', async () => {
      const immichWal = {
        ...makeImmichWal(),
        isEnabledFor: jest.fn<() => Promise<boolean>>().mockResolvedValue(false),
      };
      const { job, context } = makeJob(undefined, undefined, undefined, immichWal);

      await job.run({ repositoryId: 'repository-1' }, context);

      expect(immichWal.backupBaseIfDue).not.toHaveBeenCalled();
      expect(immichWal.prepareSnapshot).not.toHaveBeenCalled();
    });
  });
});
