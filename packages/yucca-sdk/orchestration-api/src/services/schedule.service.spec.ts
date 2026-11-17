import type { BackupStatus } from '@futo-org/backups-api-client';
import { Reflector } from '@nestjs/core';
import { SchedulerRegistry } from '@nestjs/schedule';
import { Kysely } from 'kysely';
import { PGliteDialect } from 'kysely-pglite-dialect';
import { createPGlite } from '../bin/pglite.js';
import { BackendType, ConfigurationKey, JobName, JobStatus } from '../enum.js';
import type { GatewayEvent } from '../events/events.gateway.js';
import { BackendRepository } from '../repositories/backend.repository.js';
import { ConfigRepository } from '../repositories/config.repository.js';
import { DatabaseRepository } from '../repositories/database.repository.js';
import { JobRepository } from '../repositories/job.repository.js';
import { LoggingRepository } from '../repositories/logging.repository.js';
import { RepositoryRepository } from '../repositories/repository.repository.js';
import { RepositoryIntegrationImmichRepository } from '../repositories/repositoryIntegrationImmich.repository.js';
import { ScheduleRepository } from '../repositories/schedule.repository.js';
import { StorageRepository } from '../repositories/storage.repository.js';
import type { DB } from '../schema/index.js';
import { ScheduleService } from './schedule.service.js';

type Events = { publish: (event: GatewayEvent) => void };

const noEvents: Events = { publish: () => {} };

const createService = (
  db: Kysely<DB>,
  registry: SchedulerRegistry,
  events = noEvents,
  backend: Pick<BackendRepository, 'getBackend'> = new BackendRepository(db),
) =>
  new ScheduleService(
    events as never,
    new ScheduleRepository(db),
    registry,
    { hasLock: () => true } as never,
    new RepositoryIntegrationImmichRepository(db),
    { submitStructuredLog: () => {} } as never,
    new JobRepository(
      db,
      {} as never,
      new Reflector(),
      { hasLock: () => false } as never,
      {} as never,
      events as never,
      LoggingRepository.create(),
      {} as never,
      {} as never,
      {} as never,
      {} as never,
    ),
    new ConfigRepository(db, { statePath: '/state' } as never, LoggingRepository.create()),
    new RepositoryRepository(db),
    backend as never,
  );

const reportingBackend = (submitMetricBackupEnd: (remoteId: string, status: BackupStatus) => void) => {
  const { promise: lastReported, resolve } = Promise.withResolvers<void>();
  const backend = {
    isMetricsCapable: () => true,
    submitMetricBackupEnd: (remoteId: string, status: BackupStatus) => {
      if (remoteId === 'queued') {
        resolve();
      }

      submitMetricBackupEnd(remoteId, status);
    },
  };

  return { lastReported, backendRepository: { getBackend: () => Promise.resolve({ backend } as never) } };
};

describe(ScheduleService.name, () => {
  let db: Kysely<DB>;
  let registry: SchedulerRegistry;
  let service: ScheduleService;

  beforeAll(async () => {
    const database = await createPGlite();
    db = new Kysely<DB>({ dialect: new PGliteDialect(database) });
    await new DatabaseRepository(db, new StorageRepository(), LoggingRepository.create()).runMigrations();
  }, 30_000);

  beforeEach(async () => {
    await db.deleteFrom('futo_backups_config').where('key', '=', ConfigurationKey.InstallationId).execute();
    await db.deleteFrom('futo_backups_integrations_immich_config').execute();
    await db.deleteFrom('futo_backups_schedule').execute();
    await db.deleteFrom('futo_backups_jobs').execute();
    registry = new SchedulerRegistry();
    service = createService(db, registry);
  });

  afterEach(() => {
    for (const id of registry.getCronJobs().keys()) {
      registry.deleteCronJob(id);
    }
  });

  afterAll(async () => {
    await db.destroy();
  });

  it('persists one installation identity across concurrent access and service reloads', async () => {
    const config = new ConfigRepository(db, { statePath: '/state' } as never, LoggingRepository.create());
    const ids = await Promise.all([config.getInstallationId(), config.getInstallationId()]);
    expect(ids[0]).toMatch(/^[\da-f-]{36}$/);
    expect(ids[0]).toBe(ids[1]);
    const { defaults } = await service.getSchedules();
    const reloaded = createService(db, registry);
    expect(await reloaded.getScheduleDefaults()).toEqual(defaults);
    expect(await config.getInstallationId()).toBe(ids[0]);
  });

  it('spreads minutes and days across installations within valid overnight bounds', async () => {
    const minutes = new Set<number>();
    const weekdays = new Set<number>();
    const monthdays = new Set<number>();
    for (let i = 0; i < 128; i++) {
      await db
        .insertInto('futo_backups_config')
        .values({ key: ConfigurationKey.InstallationId, value: { id: `installation-${i}` } })
        .onConflict((oc) => oc.column('key').doUpdateSet({ value: { id: `installation-${i}` } }))
        .execute();
      const defaults = await service.getScheduleDefaults();
      const minute = Number(defaults.daily.split(' ')[0]);
      const weekday = Number(defaults.weekly.split(' ')[4]);
      const monthday = Number(defaults.monthly.split(' ')[2]);
      expect(minute).toBeGreaterThanOrEqual(0);
      expect(minute).toBeLessThan(60);
      expect(weekday).toBeGreaterThanOrEqual(0);
      expect(weekday).toBeLessThan(7);
      expect(monthday).toBeGreaterThanOrEqual(1);
      expect(monthday).toBeLessThanOrEqual(28);
      expect(defaults.daily).toBe(`${minute} 3 * * *`);
      expect(defaults.weekly).toBe(`${minute} 3 * * ${weekday}`);
      expect(defaults.monthly).toBe(`${minute} 3 ${monthday} * *`);
      minutes.add(minute);
      weekdays.add(weekday);
      monthdays.add(monthday);
    }

    expect(minutes.size).toBeGreaterThan(40);
    expect(weekdays.size).toBe(7);
    expect(monthdays.size).toBeGreaterThan(24);
  });

  it('keeps presets as chosen and registers them with the installation default expression', async () => {
    const { defaults } = await service.getSchedules();
    const { schedule } = await service.createSchedule({
      name: 'Preset',
      paused: true,
      cron: '@weekly',
      repositories: [],
    });
    expect(await new ScheduleRepository(db).get(schedule.id)).toMatchObject({ cron: '@weekly' });
    expect(String(registry.getCronJob(schedule.id).cronTime.source)).toBe(defaults.weekly);

    await service.updateSchedule(schedule.id, { cron: '@monthly' });
    expect(await new ScheduleRepository(db).get(schedule.id)).toMatchObject({ cron: '@monthly' });
    expect(String(registry.getCronJob(schedule.id).cronTime.source)).toBe(defaults.monthly);
  });

  it('registers custom expressions as written', async () => {
    const { schedule } = await service.createSchedule({
      name: 'Custom',
      paused: true,
      cron: '17 4 * * 4',
      repositories: [],
    });
    expect(String(registry.getCronJob(schedule.id).cronTime.source)).toBe('17 4 * * 4');
  });

  it('resolves stored presets when registering schedules at bootstrap', async () => {
    const { defaults } = await service.getSchedules();
    const id = '6f6b0e8a-5c1a-4a43-9e0e-7d3f1f1c2b10';
    await new ScheduleRepository(db).create({ id, name: 'Stored', paused: true, cron: '@daily', ordering: [] });
    await service.bootstrap();
    expect(String(registry.getCronJob(id).cronTime.source)).toBe(defaults.daily);
  });

  const runScheduleWithActiveBackups = async (backendRepository?: Pick<BackendRepository, 'getBackend'>) => {
    const backend = await db
      .insertInto('futo_backups_backends')
      .values({ configuration: { type: BackendType.Local, path: '/test-backups' } })
      .returningAll()
      .executeTakeFirstOrThrow();
    const [running, queued, idle] = await db
      .insertInto('futo_backups_repositories')
      .values(
        ['running', 'queued', 'idle'].map((remoteId) => ({ backendId: backend.id, remoteId, retentionPolicy: {} })),
      )
      .returningAll()
      .execute();
    const backupJob = (repositoryId: string, status: JobStatus) => ({
      name: JobName.RepositoryBackup,
      repositoryId,
      data: { repositoryId },
      status,
      logFilePath: 'logs/jobs/existing.jsonl',
    });
    await db
      .insertInto('futo_backups_jobs')
      .values([backupJob(running.id, JobStatus.Running), backupJob(queued.id, JobStatus.Queued)])
      .execute();

    const { promise: jobCreated, resolve } = Promise.withResolvers<void>();
    const scheduled = createService(
      db,
      registry,
      {
        publish: (event) => {
          if (event.type === 'JobCreate') {
            resolve();
          }
        },
      },
      backendRepository,
    );
    const { schedule } = await scheduled.createSchedule({
      name: 'Nightly',
      paused: true,
      cron: '@daily',
      repositories: [running.id, queued.id, idle.id],
    });

    await registry.getCronJob(schedule.id).fireOnTick();
    await jobCreated;

    return { running, queued, idle };
  };

  it('queues a scheduled backup only for repositories without one already queued or running', async () => {
    const { running, queued, idle } = await runScheduleWithActiveBackups();

    const jobs = await db
      .selectFrom('futo_backups_jobs')
      .select(['repositoryId', 'status'])
      .where('name', '=', JobName.RepositoryBackup)
      .orderBy('sequence')
      .execute();
    expect(jobs).toEqual([
      { repositoryId: running.id, status: JobStatus.Running },
      { repositoryId: queued.id, status: JobStatus.Queued },
      { repositoryId: idle.id, status: JobStatus.Queued },
    ]);
  });

  it('reports a skipped backup for each repository with one already queued or running', async () => {
    const reported: [string, BackupStatus][] = [];
    const { lastReported, backendRepository } = reportingBackend((remoteId, status) =>
      reported.push([remoteId, status]),
    );

    await runScheduleWithActiveBackups(backendRepository);
    await lastReported;

    expect(reported).toEqual([
      ['running', 'skipped'],
      ['queued', 'skipped'],
    ]);
  });

  it('keeps reporting skipped backups after one report fails', async () => {
    const reported: string[] = [];
    const { lastReported, backendRepository } = reportingBackend((remoteId) => {
      if (remoteId === 'running') {
        throw new Error('backend unavailable');
      }

      reported.push(remoteId);
    });

    await runScheduleWithActiveBackups(backendRepository);
    await lastReported;

    expect(reported).toEqual(['queued']);
  });
});
