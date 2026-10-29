import {
  createRepository,
  createResticUrl,
  createTicket,
  getRepositories,
  getRepository,
  submitMetricBackupEnd,
  submitMetricBackupStart,
} from '@futo-org/backups-api-client';
import { ResticBackupCommandCouldNotReadSourceDataError } from '@futo-org/restic-wrapper';
import { jest } from '@jest/globals';
import { GoneException, NotFoundException } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { mkdir, readdir } from 'node:fs/promises';
import { LocalBackend } from '../src/backends/local.backend.js';
import { BackendType, JobName, TaskStatus, TicketAction } from '../src/enum.js';
import { ResticProxyPool } from '../src/proxy/resticProxyPool.js';
import { BackendRepository } from '../src/repositories/backend.repository.js';
import { JobRepository } from '../src/repositories/job.repository.js';
import { ModuleConfigRepository } from '../src/repositories/moduleConfig.repository.js';
import { RepositoryRepository } from '../src/repositories/repository.repository.js';
import { RepositoryIntegrationImmichRepository } from '../src/repositories/repositoryIntegrationImmich.repository.js';
import { AuthService } from '../src/services/auth.service.js';
import { IntegrationsService } from '../src/services/integrations.service.js';
import { RepositoryService } from '../src/services/repository.service.js';
import { YuccaService } from '../src/services/yucca.service.js';
import { newImmichHooksMock } from './mocks.js';
import { createTestingModule, TestContext, waitFor, waitForEvent } from './testUtils.js';

let ctx: TestContext;

const configureImmich = async (hooks: Partial<ReturnType<typeof newImmichHooksMock>>) => {
  const integrationsService = ctx.module.get(IntegrationsService);
  const moduleConfig = ctx.module.get(ModuleConfigRepository);
  const immichRepository = ctx.module.get(RepositoryIntegrationImmichRepository);

  moduleConfig.update({
    immichIntegration: {
      dataPath: '/data/immich',
      dataFolders: ['upload'],
      libraries: [],
      hooks: { ...newImmichHooksMock(), ...hooks },
    },
  });

  await integrationsService.configureImmichIntegration({
    name: 'Immich Backup',
    worm: false,
    cron: '0 2 * * *',
    dataFolders: ['upload'],
    backupConfiguration: false,
    libraries: ['all'],
  });

  const integration = await immichRepository.get();

  return {
    repositoryId: integration!.id,
    teardown: async () => {
      await immichRepository.delete();
      moduleConfig.update({ immichIntegration: undefined });
    },
  };
};

const backupWithHooks = async (hooks: Partial<ReturnType<typeof newImmichHooksMock>>) => {
  const repositoryService = ctx.module.get(RepositoryService);
  const { repositoryId, teardown } = await configureImmich(hooks);

  try {
    const { jobId } = await repositoryService.createBackup(repositoryId);
    await ctx.module.get(JobRepository).wait(jobId);
  } finally {
    await teardown();
  }
};

const restoreSnapshotTaggedWith = async (tags: string[] | undefined) => {
  const { repositoryId, teardown } = await configureImmich({});
  ctx.resticMock.snapshot.mockResolvedValue([{ id: 'snapshot-1', time: new Date(), tags }] as never);

  try {
    const { task, immichBackupFileName } = await ctx.module
      .get(YuccaService)
      .restoreSnapshotInplace(repositoryId, 'snapshot-1');
    await task;
    return immichBackupFileName;
  } finally {
    await teardown();
  }
};

beforeAll(async () => {
  ctx = await createTestingModule();
}, 15_000);

afterAll(async () => {
  await ctx.app.close();
});

describe('Repository', () => {
  beforeEach(() => {
    ctx.resticMock.backup.mockReset();
    ctx.resticMock.forget.mockReset();
    ctx.resticMock.stats.mockResolvedValue({ total_size: 1024, snapshots_count: 1 });
  });

  it('runs a forget requested during a backup once the backup finishes', async () => {
    const repositoryService = ctx.module.get(RepositoryService);

    const { repository } = await repositoryService.createRepository(
      { name: 'Queued Repo', worm: false, paths: ['/tmp/queued'] },
      ctx.backendId,
    );

    const backupRunning = Promise.withResolvers<void>();
    const releaseBackup = Promise.withResolvers<void>();
    ctx.resticMock.backup.mockImplementationOnce(() => {
      backupRunning.resolve();
      return releaseBackup.promise as never;
    });

    const backup = await repositoryService.createBackup(repository.id);
    await backupRunning.promise;

    const queuedJob = waitForEvent(ctx.events, 'JobCreate');
    const forget = repositoryService.forgetSnapshot(repository.id, 'snapshot-1');
    await queuedJob;
    expect(ctx.resticMock.forget).not.toHaveBeenCalled();

    releaseBackup.resolve();
    await ctx.module.get(JobRepository).wait(backup.jobId);
    await forget;

    expect(ctx.resticMock.forget).toHaveBeenCalledTimes(1);
    expect(ctx.resticMock.backup.mock.invocationCallOrder[0]).toBeLessThan(
      ctx.resticMock.forget.mock.invocationCallOrder[0],
    );
  });

  it('uses the snapshot of the previous backup as the parent of the next one', async () => {
    const repositoryService = ctx.module.get(RepositoryService);
    const jobs = ctx.module.get(JobRepository);

    const { repository } = await repositoryService.createRepository(
      { name: 'Parent Repo', worm: false, paths: ['/tmp/parent'] },
      ctx.backendId,
    );

    ctx.resticMock.backup.mockImplementationOnce((...args: unknown[]) => {
      const log = args[4] as (event: object) => void;
      log({ message_type: 'summary', files_new: 1, files_changed: 0, snapshot_id: 'snapshot-a' });
      return Promise.resolve({ snapshot_id: 'snapshot-a' }) as never;
    });
    ctx.resticMock.snapshot.mockResolvedValue([{ id: 'snapshot-a', time: new Date() }] as never);

    const first = await repositoryService.createBackup(repository.id);
    await jobs.wait(first.jobId);
    const second = await repositoryService.createBackup(repository.id);
    await jobs.wait(second.jobId);

    expect(ctx.resticMock.backup).toHaveBeenCalledTimes(2);
    expect(ctx.resticMock.backup.mock.calls[0][7]).toBeUndefined();
    expect(ctx.resticMock.backup.mock.calls[1][7]).toBe('snapshot-a');
    expect(ctx.resticMock.snapshot).toHaveBeenCalledWith(
      expect.anything(),
      expect.anything(),
      expect.anything(),
      'snapshot-a',
      expect.any(AbortSignal),
    );
  });

  it('rejects backup when no paths are configured', async () => {
    const repositoryService = ctx.module.get(RepositoryService);

    const { repository } = await repositoryService.createRepository(
      { name: 'No Paths Repo', worm: false },
      ctx.backendId,
    );

    await expect(repositoryService.createBackup(repository.id)).rejects.toThrow('Missing configuration paths');
  });

  it('updates metrics after successful backup', async () => {
    const repositoryService = ctx.module.get(RepositoryService);

    const { repository } = await repositoryService.createRepository(
      { name: 'Metrics Repo', worm: false, paths: ['/tmp/metrics'] },
      ctx.backendId,
    );

    const statusEvent = waitForEvent(
      ctx.events,
      'RepositoryUpdate',
      (event) => event.type === 'RepositoryUpdate' && event.repositoryId === repository.id,
    );
    const sizeEvent = waitForEvent(
      ctx.events,
      'RepositoryUpdate',
      (event) =>
        event.type === 'RepositoryUpdate' &&
        event.repositoryId === repository.id &&
        event.repository.metrics?.sizeBytes === 1024,
    );

    const { jobId } = await repositoryService.createBackup(repository.id);
    await ctx.module.get(JobRepository).wait(jobId);

    expect(jobId).toEqual(expect.any(String));

    await expect(statusEvent).resolves.toEqual(
      expect.objectContaining({
        type: 'RepositoryUpdate',
        repositoryId: repository.id,
        repository: expect.objectContaining({
          metrics: expect.objectContaining({
            sizeBytes: 0,
            lastBackup: expect.any(String),
            lastBackupStatus: TaskStatus.Complete,
          }),
        }),
      }),
    );

    await expect(sizeEvent).resolves.toEqual(
      expect.objectContaining({
        type: 'RepositoryUpdate',
        repositoryId: repository.id,
        repository: expect.objectContaining({
          metrics: expect.objectContaining({
            sizeBytes: 1024,
            lastBackup: expect.any(String),
            lastBackupStatus: TaskStatus.Complete,
          }),
        }),
      }),
    );
  });

  describe('Immich integration hooks', () => {
    it('passes the task abort signal to the database backup hook and tags the snapshot', async () => {
      const createDatabaseBackup = jest.fn().mockResolvedValue('dump.sql.gz');

      await backupWithHooks({ createDatabaseBackup });

      expect(createDatabaseBackup).toHaveBeenCalledWith(expect.any(AbortSignal));
      expect(ctx.resticMock.backup).toHaveBeenCalledWith(
        expect.anything(),
        expect.anything(),
        expect.anything(),
        expect.anything(),
        expect.anything(),
        expect.any(AbortSignal),
        ['yucca.v1.immichBackupFileName=dump.sql.gz'],
        undefined,
      );
    });

    it('runs cleanup after the backup succeeds', async () => {
      const cleanupDatabaseBackups = jest.fn();

      await backupWithHooks({
        createDatabaseBackup: jest.fn().mockResolvedValue('dump.sql.gz'),
        cleanupDatabaseBackups,
      });

      expect(cleanupDatabaseBackups).toHaveBeenCalledTimes(1);
      expect(cleanupDatabaseBackups.mock.invocationCallOrder[0]).toBeGreaterThan(
        ctx.resticMock.backup.mock.invocationCallOrder[0],
      );
    });

    it('skips cleanup when the backup fails', async () => {
      const cleanupDatabaseBackups = jest.fn();
      ctx.resticMock.backup.mockRejectedValue(new Error('Backup failed'));

      await expect(backupWithHooks({ cleanupDatabaseBackups })).rejects.toThrow('Backup failed');

      expect(cleanupDatabaseBackups).not.toHaveBeenCalled();
    });

    it('still backs up without a tag and finishes with a warning when the database backup hook fails', async () => {
      const metricsEvent = waitForEvent(
        ctx.events,
        'RepositoryUpdate',
        (event) => event.type === 'RepositoryUpdate' && event.repository.metrics?.lastBackupStatus === TaskStatus.Warn,
      );

      await expect(
        backupWithHooks({ createDatabaseBackup: jest.fn().mockRejectedValue(new Error('pg_dump failed')) }),
      ).rejects.toMatchObject({
        message: 'Task finished with warnings',
        errors: [expect.objectContaining({ message: 'Database dump failed: Error: pg_dump failed' })],
      });

      await expect(metricsEvent).resolves.toEqual(
        expect.objectContaining({
          repository: expect.objectContaining({
            metrics: expect.objectContaining({ lastBackupStatus: TaskStatus.Warn }),
          }),
        }),
      );
      expect(ctx.resticMock.backup).toHaveBeenCalledWith(
        expect.anything(),
        expect.anything(),
        expect.anything(),
        expect.anything(),
        expect.anything(),
        expect.any(AbortSignal),
        [],
        undefined,
      );
    });

    it('finishes with a warning when cleanup rejects', async () => {
      await expect(
        backupWithHooks({ cleanupDatabaseBackups: jest.fn().mockRejectedValue(new Error('locked')) }),
      ).rejects.toMatchObject({
        errors: [expect.objectContaining({ message: 'Database backup cleanup failed: Error: locked' })],
      });
    });

    it('collects every hook failure into one warning', async () => {
      await expect(
        backupWithHooks({
          createDatabaseBackup: jest.fn().mockRejectedValue(new Error('pg_dump failed')),
          cleanupDatabaseBackups: jest.fn().mockRejectedValue(new Error('locked')),
        }),
      ).rejects.toMatchObject({
        errors: [
          expect.objectContaining({ message: 'Database dump failed: Error: pg_dump failed' }),
          expect.objectContaining({ message: 'Database backup cleanup failed: Error: locked' }),
        ],
      });
    });
  });

  describe('in-place snapshot restore', () => {
    it('returns the database dump file name tagged on the snapshot', async () => {
      await expect(
        restoreSnapshotTaggedWith(['other=value', 'yucca.v1.immichBackupFileName=dump.sql.gz']),
      ).resolves.toBe('dump.sql.gz');
    });

    it('returns no database dump file name for an untagged snapshot', async () => {
      await expect(restoreSnapshotTaggedWith(undefined)).resolves.toBeUndefined();
    });
  });

  it('sets lastBackupStatus to failed on failure', async () => {
    const repositoryService = ctx.module.get(RepositoryService);

    const { repository } = await repositoryService.createRepository(
      { name: 'Fail Metrics Repo', worm: false, paths: ['/tmp/fail-metrics'] },
      ctx.backendId,
    );

    ctx.resticMock.backup.mockRejectedValue(new Error('Backup failed'));

    const metricsEvent = waitForEvent(
      ctx.events,
      'RepositoryUpdate',
      (event) => event.type === 'RepositoryUpdate' && event.repositoryId === repository.id,
    );

    const { jobId } = await repositoryService.createBackup(repository.id);
    await ctx.module
      .get(JobRepository)
      .wait(jobId)
      .catch(() => {});

    const event = await metricsEvent;
    expect(event).toEqual(
      expect.objectContaining({
        type: 'RepositoryUpdate',
        repositoryId: repository.id,
        repository: expect.objectContaining({
          metrics: expect.objectContaining({
            lastBackup: expect.any(String),
            lastBackupStatus: TaskStatus.Failed,
          }),
        }),
      }),
    );
  });

  it('reports warn without rejecting when source data could not be read', async () => {
    const repositoryService = ctx.module.get(RepositoryService);

    const { repository } = await repositoryService.createRepository(
      { name: 'Warn Metrics Repo', worm: false, paths: ['/tmp/warn-metrics'] },
      ctx.backendId,
    );

    ctx.resticMock.backup.mockRejectedValue(new ResticBackupCommandCouldNotReadSourceDataError('unreadable'));

    const metricsEvent = waitForEvent(
      ctx.events,
      'RepositoryUpdate',
      (event) => event.type === 'RepositoryUpdate' && event.repositoryId === repository.id,
    );

    const { jobId } = await repositoryService.createBackup(repository.id);
    await ctx.module
      .get(JobRepository)
      .wait(jobId)
      .catch(() => {});

    await expect(metricsEvent).resolves.toEqual(
      expect.objectContaining({
        type: 'RepositoryUpdate',
        repositoryId: repository.id,
        repository: expect.objectContaining({
          metrics: expect.objectContaining({
            lastBackup: expect.any(String),
            lastBackupStatus: TaskStatus.Warn,
          }),
        }),
      }),
    );
  });

  it('skips pruning after a backup with warnings', async () => {
    const repositoryService = ctx.module.get(RepositoryService);
    const jobs = ctx.module.get(JobRepository);

    const { repository } = await repositoryService.createRepository(
      { name: 'Warn Prune Repo', worm: false, paths: ['/tmp/warn-prune'] },
      ctx.backendId,
    );

    ctx.resticMock.backup.mockRejectedValueOnce(new ResticBackupCommandCouldNotReadSourceDataError('unreadable'));

    const { jobId } = await repositoryService.createBackup(repository.id);
    await expect(jobs.wait(jobId)).rejects.toThrow('Task finished with warnings');

    const queued = await jobs.getAll(repository.id);
    const names = queued.map((job) => job.name);
    expect(names).not.toContain(JobName.RepositoryPrune);
    expect(names).toContain(JobName.RepositorySyncMetrics);
  });

  it('leaves the metrics sync to the prune when a backup queues one', async () => {
    const repositoryService = ctx.module.get(RepositoryService);
    const jobs = ctx.module.get(JobRepository);

    const { repository } = await repositoryService.createRepository(
      { name: 'Prune Sync Repo', worm: false, paths: ['/tmp/prune-sync'] },
      ctx.backendId,
    );

    const { jobId } = await repositoryService.createBackup(repository.id);
    await jobs.wait(jobId);
    const queued = await jobs.getAll(repository.id);
    await Promise.allSettled(queued.map((job) => jobs.wait(job.id)));

    const all = await jobs.getAll(repository.id);
    const names = all.map((job) => job.name);
    expect(names.filter((name) => name === JobName.RepositoryPrune)).toHaveLength(1);
    expect(names.filter((name) => name === JobName.RepositorySyncMetrics)).toHaveLength(1);
  });

  it('records a cancelled backup without pruning or syncing metrics', async () => {
    const repositoryService = ctx.module.get(RepositoryService);
    const jobs = ctx.module.get(JobRepository);

    const { repository } = await repositoryService.createRepository(
      { name: 'Cancelled Repo', worm: false, paths: ['/tmp/cancelled'] },
      ctx.backendId,
    );

    const started = Promise.withResolvers<void>();
    ctx.resticMock.backup.mockImplementationOnce(
      (...args: unknown[]) =>
        new Promise((_, reject) => {
          started.resolve();
          const signal = args[5] as AbortSignal;
          signal.addEventListener('abort', () => reject(signal.reason), { once: true });
        }) as never,
    );

    const cancelledEvent = waitForEvent(
      ctx.events,
      'RepositoryUpdate',
      (event) =>
        event.type === 'RepositoryUpdate' &&
        event.repositoryId === repository.id &&
        event.repository.metrics?.lastBackupStatus === TaskStatus.Cancelled,
    );

    const { jobId } = await repositoryService.createBackup(repository.id);
    await started.promise;
    await jobs.cancel(jobId);

    await expect(jobs.wait(jobId)).rejects.toThrow('Cancelled by user action');
    await expect(cancelledEvent).resolves.toBeDefined();

    const all = await jobs.getAll(repository.id);
    const names = all.map((job) => job.name);
    expect(names).not.toContain(JobName.RepositoryPrune);
    expect(names).not.toContain(JobName.RepositorySyncMetrics);
  });

  it('reports the start and end of a backup to a metrics-capable backend', async () => {
    const repositoryService = ctx.module.get(RepositoryService);
    const jobs = ctx.module.get(JobRepository);
    const yuccaBackendId = randomUUID();
    const remoteId = randomUUID();

    jest.spyOn(ResticProxyPool.prototype, 'isAvailable').mockResolvedValue(false);
    (createResticUrl as jest.Mock).mockResolvedValue({ url: 'rest:http://yucca.test/restic' });
    (createRepository as jest.Mock).mockResolvedValueOnce(remoteRepository(remoteId, 'Metered'));
    (getRepository as jest.Mock).mockResolvedValue(remoteRepository(remoteId, 'Metered'));
    (submitMetricBackupStart as jest.Mock).mockClear();
    (submitMetricBackupEnd as jest.Mock).mockClear();

    await ctx.module.get(BackendRepository).updateBackend(yuccaBackendId, {
      type: BackendType.Yucca,
      url: 'http://yucca.test',
      accessToken: 'test-token',
    });
    const { repository } = await repositoryService.createRepository(
      { name: 'Metered', worm: false, paths: ['/tmp/metered'] },
      yuccaBackendId,
    );

    try {
      const { jobId } = await repositoryService.createBackup(repository.id);
      await jobs.wait(jobId);
      await waitFor(() => (submitMetricBackupEnd as jest.Mock).mock.calls.length > 0);

      expect(submitMetricBackupStart).toHaveBeenCalledWith(remoteId, expect.anything());
      expect(submitMetricBackupEnd).toHaveBeenCalledWith(
        remoteId,
        { durationMs: expect.any(Number), status: TaskStatus.Complete },
        expect.anything(),
      );
    } finally {
      jest.restoreAllMocks();
      await repositoryService.deleteRepository(repository.id);
      await ctx.db.deleteFrom('futo_backups_backends').where('id', '=', yuccaBackendId).execute();
    }
  });

  it('syncs the metrics itself when a backup has no retention policy to prune by', async () => {
    const repositoryService = ctx.module.get(RepositoryService);
    const jobs = ctx.module.get(JobRepository);

    const { repository } = await repositoryService.createRepository(
      { name: 'No Prune Sync Repo', worm: false, paths: ['/tmp/no-prune-sync'], retentionPolicy: null },
      ctx.backendId,
    );

    const { jobId } = await repositoryService.createBackup(repository.id);
    await jobs.wait(jobId);

    const all = await jobs.getAll(repository.id);
    const names = all.map((job) => job.name);
    expect(names).not.toContain(JobName.RepositoryPrune);
    expect(names.filter((name) => name === JobName.RepositorySyncMetrics)).toHaveLength(1);
  });

  it('shows offline status when backend errors', async () => {
    const repositoryService = ctx.module.get(RepositoryService);
    const backendRepository = ctx.module.get(BackendRepository);

    const { repository } = await repositoryService.createRepository(
      { name: 'Offline Test', worm: false },
      ctx.backendId,
    );

    await backendRepository.updateBackend(ctx.backendId, {
      type: 'local' as any,
      path: '/nonexistent/broken/path',
    });

    const { repositories } = await repositoryService.getRepositories();
    const offlineRepo = repositories.find((repo) => repo.id === repository.id);

    expect(offlineRepo).toBeDefined();
    expect(offlineRepo?.backends?.primary.online).toBe(false);
    expect(offlineRepo?.name).toBe('Unknown');

    await backendRepository.updateBackend(ctx.backendId, {
      type: 'local' as any,
      path: ctx.backendPath,
    });
  });

  describe('deleted from FUTO Backups', () => {
    const notFound = () => Object.assign(new Error('Error: 404'), { status: 404 });
    let yuccaBackendId: string;
    let remoteId: string;
    let repositoryId: string;

    beforeEach(async () => {
      yuccaBackendId = randomUUID();
      remoteId = randomUUID();

      await ctx.module.get(BackendRepository).updateBackend(yuccaBackendId, {
        type: BackendType.Yucca,
        url: 'http://yucca.test',
        accessToken: 'test-token',
      });
      (createRepository as jest.Mock).mockResolvedValueOnce(remoteRepository(remoteId, 'Deleted'));
      const { repository } = await ctx.module
        .get(RepositoryService)
        .createRepository({ name: 'Deleted', worm: false }, yuccaBackendId);
      repositoryId = repository.id;
    });

    afterEach(async () => {
      await ctx.module.get(RepositoryService).deleteRepository(repositoryId);
      await ctx.db.deleteFrom('futo_backups_backends').where('id', '=', yuccaBackendId).execute();
    });

    const isKnownLocally = async () => Boolean(await ctx.module.get(RepositoryRepository).get(repositoryId));

    it('lists the leftover repository as unknown and offline', async () => {
      (getRepositories as jest.Mock).mockResolvedValueOnce({ repositories: [] });

      const { repositories } = await ctx.module.get(RepositoryService).getRepositories();
      expect(repositories.find(({ id }) => id === repositoryId)).toMatchObject({
        name: 'Unknown',
        backends: { primary: { online: false } },
      });
    });

    it('reports the repository as gone when creating a ticket', async () => {
      (createTicket as jest.Mock).mockRejectedValueOnce(notFound());

      await expect(
        ctx.module.get(AuthService).createTicket({ action: TicketAction.DeleteRepository, repositoryId }),
      ).rejects.toBeInstanceOf(GoneException);
      expect(await isKnownLocally()).toBe(true);
    });

    it('reports a repository unknown locally as not found when creating a ticket', async () => {
      (createTicket as jest.Mock).mockClear();

      await expect(
        ctx.module.get(AuthService).createTicket({ action: TicketAction.DeleteRepository, repositoryId: randomUUID() }),
      ).rejects.toBeInstanceOf(NotFoundException);
      expect(createTicket).not.toHaveBeenCalled();
    });

    it('passes other backend failures through when creating a ticket', async () => {
      const failure = Object.assign(new Error('Error: 500'), { status: 500 });
      (createTicket as jest.Mock).mockRejectedValueOnce(failure);

      await expect(
        ctx.module.get(AuthService).createTicket({ action: TicketAction.DeleteRepository, repositoryId }),
      ).rejects.toBe(failure);
    });

    it('removes the repository once it has been deleted remotely', async () => {
      (getRepository as jest.Mock).mockRejectedValueOnce(notFound());

      await expect(ctx.module.get(RepositoryService).syncDeletion(repositoryId)).resolves.toEqual({ deleted: true });
      expect(getRepository).toHaveBeenCalledWith(remoteId, expect.anything());
      expect(await isKnownLocally()).toBe(false);
    });

    it('keeps the repository while it still exists remotely', async () => {
      (getRepository as jest.Mock).mockResolvedValueOnce(remoteRepository(remoteId, 'Deleted'));

      await expect(ctx.module.get(RepositoryService).syncDeletion(repositoryId)).resolves.toEqual({ deleted: false });
      expect(await isKnownLocally()).toBe(true);
    });

    it('keeps the repository when the backend fails', async () => {
      (getRepository as jest.Mock).mockRejectedValueOnce(Object.assign(new Error('Error: 500'), { status: 500 }));

      await expect(ctx.module.get(RepositoryService).syncDeletion(repositoryId)).rejects.toThrow('Error: 500');
      expect(await isKnownLocally()).toBe(true);
    });
  });

  it('lists remote-only repositories not in local database', async () => {
    const repositoryService = ctx.module.get(RepositoryService);

    const remoteOnlyId = randomUUID();
    await mkdir(`${ctx.backendPath}/${remoteOnlyId}`, { recursive: true });

    const { repositories } = await repositoryService.getRepositories();
    const remoteOnly = repositories.find((repo) => repo.id === remoteOnlyId);

    expect(remoteOnly).toBeDefined();
    expect(remoteOnly?.name).toBe('Unknown');
    expect(remoteOnly?.backends?.primary.online).toBe(true);
  });

  it('lists a local repository under the name it was created with', async () => {
    const repositoryService = ctx.module.get(RepositoryService);

    const { repository } = await repositoryService.createRepository({ name: 'Immich', worm: false }, ctx.backendId);

    const { repositories } = await repositoryService.getRepositories();

    expect(repositories.find((repo) => repo.id === repository.id)?.name).toBe('Immich');
  });

  describe('after a fresh install pointed at an existing local backend', () => {
    const createRepositoryFromPreviousInstall = async (name: string) => {
      const { repository } = await new LocalBackend({
        type: BackendType.Local,
        path: ctx.backendPath,
      }).createRepository({ name, worm: false });
      return repository.id;
    };

    it('offers the repository for restore under its stored name', async () => {
      const remoteId = await createRepositoryFromPreviousInstall('Immich');

      const { repositories } = await ctx.module.get(RepositoryService).inspectRepositories(ctx.backendId);

      expect(repositories.find((repo) => repo.id === remoteId)).toEqual(
        expect.objectContaining({ name: 'Immich', snapshots: [] }),
      );
    });

    it('keeps the stored name when importing the repository', async () => {
      const repositoryService = ctx.module.get(RepositoryService);
      const remoteId = await createRepositoryFromPreviousInstall('Immich');

      const { repository } = await repositoryService.importRepository(remoteId, ctx.backendId);
      const { repositories } = await repositoryService.getRepositories();

      expect(repository.name).toBe('Immich');
      expect(repositories.find((repo) => repo.id === repository.id)?.name).toBe('Immich');
    });
  });
});

const remoteRepository = (id: string, name: string) => ({
  repository: {
    id,
    name,
    worm: false,
    siteCode: null,
    storageClusterCode: null,
    connectionId: '',
    connectionType: 'restic',
    metrics: { sizeBytes: 0 },
  },
});

describe('Primary backend reconfiguration', () => {
  beforeEach(() => {
    ctx.resticMock.init.mockReset();
    jest.spyOn(ResticProxyPool.prototype, 'isAvailable').mockResolvedValue(false);
    (createResticUrl as jest.Mock).mockResolvedValue({ url: 'rest:http://yucca.test/restic' });
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('keeps the repository name when moving to another backend', async () => {
    const repositoryService = ctx.module.get(RepositoryService);
    const yuccaBackendId = randomUUID();
    await ctx.module.get(BackendRepository).updateBackend(yuccaBackendId, {
      type: BackendType.Yucca,
      url: 'http://yucca.test',
      accessToken: 'test-token',
    });

    const remoteId = randomUUID();
    (createRepository as jest.Mock).mockResolvedValueOnce(remoteRepository(remoteId, 'Family Photos'));
    (getRepository as jest.Mock).mockResolvedValueOnce(remoteRepository(remoteId, 'Family Photos'));
    const { repository } = await repositoryService.createRepository(
      { name: 'Family Photos', worm: false },
      yuccaBackendId,
    );

    const { repository: moved } = await repositoryService.reconfigureRepositoryPrimaryBackend(repository.id, {
      backendId: ctx.backendId,
    });

    expect(getRepository).toHaveBeenCalledWith(remoteId, expect.any(Object));
    expect(moved).toEqual(expect.objectContaining({ id: repository.id, name: 'Family Photos' }));
  });

  it('keeps the name of a local repository when moving to another backend', async () => {
    const repositoryService = ctx.module.get(RepositoryService);

    const { repository } = await repositoryService.createRepository({ name: 'Local Only', worm: false }, ctx.backendId);

    const { repository: moved } = await repositoryService.reconfigureRepositoryPrimaryBackend(repository.id, {
      backendId: ctx.backendId,
    });

    expect(moved.name).toBe('Local Only');
  });

  it('names the repository as restored when the old backend cannot report its name', async () => {
    const repositoryService = ctx.module.get(RepositoryService);
    const yuccaBackendId = randomUUID();
    await ctx.module.get(BackendRepository).updateBackend(yuccaBackendId, {
      type: BackendType.Yucca,
      url: 'http://yucca.test',
      accessToken: 'test-token',
    });

    (createRepository as jest.Mock).mockResolvedValueOnce(remoteRepository(randomUUID(), 'Unreachable'));
    (getRepository as jest.Mock).mockRejectedValueOnce(new Error('Backend is offline'));
    const { repository } = await repositoryService.createRepository(
      { name: 'Unreachable', worm: false },
      yuccaBackendId,
    );

    const { repository: moved } = await repositoryService.reconfigureRepositoryPrimaryBackend(repository.id, {
      backendId: ctx.backendId,
    });

    expect(moved.name).toBe('Restored Repository');
  });

  it('rejects an unknown repository before creating anything on the new backend', async () => {
    const repositoryService = ctx.module.get(RepositoryService);
    const entriesBefore = await readdir(ctx.backendPath);

    await expect(
      repositoryService.reconfigureRepositoryPrimaryBackend(randomUUID(), { backendId: ctx.backendId }),
    ).rejects.toThrow('Repository not found locally');

    await expect(readdir(ctx.backendPath)).resolves.toEqual(entriesBefore);
    expect(ctx.resticMock.init).not.toHaveBeenCalled();
  });
});
