import { schemaDiff, schemaFromCode } from '@immich/sql-tools';
import { Reflector } from '@nestjs/core';
import { Kysely, sql } from 'kysely';
import { PGliteDialect } from 'kysely-pglite-dialect';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createPGlite } from '../bin/pglite.js';
import { Job } from '../decorators.js';
import { BackendType, ConfigurationKey, JobName, JobStatus } from '../enum.js';
import { BackendRepository } from '../repositories/backend.repository.js';
import { ConfigRepository } from '../repositories/config.repository.js';
import { JobRepository } from '../repositories/job.repository.js';
import { LoggingRepository } from '../repositories/logging.repository.js';
import { RepositoryRepository } from '../repositories/repository.repository.js';
import { RepositoryIntegrationImmichRepository } from '../repositories/repositoryIntegrationImmich.repository.js';
import { RepositoryLocalMetricsRepository } from '../repositories/repositoryLocalMetrics.repository.js';
import { RepositoryPathRepository } from '../repositories/repositoryPath.repository.js';
import { ScheduleRepository } from '../repositories/schedule.repository.js';
import { StorageRepository } from '../repositories/storage.repository.js';
import './index.js';
import type { DB } from './index.js';

describe('Postgres orchestration schema', () => {
  let db: Kysely<DB>;

  beforeAll(async () => {
    const database = await createPGlite();
    db = new Kysely<DB>({ dialect: new PGliteDialect(database) });
    const schema = schemaFromCode({ databaseName: 'futo_backups', reset: false, overrides: false });
    const empty = { ...schema, tables: [], enums: [], functions: [], extensions: [], parameters: [] };
    const statements = schemaDiff(schema, empty).asSql();

    for (const statement of statements) {
      await sql.raw(statement).execute(db);
    }
  });

  afterAll(async () => {
    await db?.destroy();
  });

  it('creates only prefixed application tables and enum types', async () => {
    const tables = await db.introspection.getTables();
    expect(tables).toHaveLength(9);
    expect(tables.every(({ name }) => name.startsWith('futo_backups_'))).toBe(true);

    const { rows } = await sql<{ name: string }>`
      SELECT typname AS name FROM pg_type WHERE typtype = 'e'
    `.execute(db);
    expect(rows).toHaveLength(4);
    expect(rows.every(({ name }) => name.startsWith('futo_backups_'))).toBe(true);
  });

  it('round-trips JSON configuration, booleans, UUID arrays, timestamps and large byte counts', async () => {
    const configuration = { type: BackendType.Local, path: '/test-backups' };
    const backend = await db
      .insertInto('futo_backups_backends')
      .values({ configuration })
      .returningAll()
      .executeTakeFirstOrThrow();
    expect(backend.configuration).toEqual(configuration);
    expect(backend.id).toMatch(/^[\da-f-]{36}$/);

    const repository = await db
      .insertInto('futo_backups_repositories')
      .values({ backendId: backend.id, remoteId: 'remote-repository', retentionPolicy: { keepLast: 3 } })
      .returningAll()
      .executeTakeFirstOrThrow();
    expect(repository.retentionPolicy).toEqual({ keepLast: 3 });
    expect(repository.siteCode).toBeNull();

    const lastRun = new Date('2026-10-27T12:00:00.000Z');
    const schedule = await db
      .insertInto('futo_backups_schedule')
      .values({ name: 'Daily', cron: '0 0 * * *', ordering: [repository.id], lastRun })
      .returningAll()
      .executeTakeFirstOrThrow();
    expect(schedule.paused).toBe(false);
    expect(schedule.ordering).toEqual([repository.id]);
    expect(schedule.lastRun).toEqual(lastRun);
    expect(schedule.lastFinished).toBeNull();

    const metrics = await db
      .insertInto('futo_backups_local_metrics')
      .values({ repositoryId: repository.id, sizeBytes: 5_000_000_000, lastBackup: lastRun, lastBackupDuration: 42 })
      .returningAll()
      .executeTakeFirstOrThrow();
    expect(Number(metrics.sizeBytes)).toBe(5_000_000_000);
    expect(metrics.lastBackup).toEqual(lastRun);
    expect(metrics.lastBackupDuration).toBe(42);

    const localMetrics = new RepositoryLocalMetricsRepository(db);
    expect(await localMetrics.get(repository.id)).toStrictEqual({
      sizeBytes: 5_000_000_000,
      lastBackup: lastRun.toISOString(),
      lastBackupStatus: null,
      lastBackupDuration: 42,
    });
    await localMetrics.save(repository.id, { lastBackupDuration: 84 });
    expect(await localMetrics.get(repository.id)).toMatchObject({ sizeBytes: 5_000_000_000, lastBackupDuration: 84 });
    const allMetrics = await localMetrics.getAll();
    expect(allMetrics.get(repository.id)).toStrictEqual({
      sizeBytes: 5_000_000_000,
      lastBackup: lastRun.toISOString(),
      lastBackupStatus: null,
      lastBackupDuration: 84,
    });
  });

  it('reads backend configuration and retention policies back as objects', async () => {
    const backends = new BackendRepository(db);
    const configuration = { type: BackendType.Local, path: '/test-objects' } as const;
    const backend = await backends.updateBackend(randomUUID(), configuration);
    expect(await backends.getBackend(backend.id)).toMatchObject({ id: backend.id, configuration });

    const moved = { ...configuration, path: '/test-objects-moved' };
    await backends.updateBackend(backend.id, moved);
    expect(await backends.getBackends()).toContainEqual(
      expect.objectContaining({ id: backend.id, configuration: moved }),
    );

    const repositories = new RepositoryRepository(db);
    const repository = await repositories.create({
      backendId: backend.id,
      remoteId: 'objects-repository',
      retentionPolicy: { keepLast: 3 },
    });
    expect(await repositories.get(repository.id)).toMatchObject({ retentionPolicy: { keepLast: 3 } });
    await repositories.update(repository.id, { retentionPolicy: null });
    expect(await repositories.get(repository.id)).toMatchObject({ retentionPolicy: null });
  });

  it('stores each configuration value as a JSON object', async () => {
    const config = new ConfigRepository(db, { statePath: '/state' } as never, LoggingRepository.create());
    await config.importEncryptionKey('test-key');
    await config.confirmKeyOnboarded();
    await config.setThrottle({ bytesPerSec: 1024, quietHours: '22:00-06:00' });

    const values = await db.selectFrom('futo_backups_config').selectAll().execute();
    expect(Object.fromEntries(values.map(({ key, value }) => [key, value]))).toEqual({
      [ConfigurationKey.EncryptionKey]: { key: 'test-key' },
      [ConfigurationKey.OnboardedKey]: { isOnboarded: true },
      [ConfigurationKey.Throttle]: { bytesPerSec: 1024, quietHours: '22:00-06:00' },
    });
    expect(await config.getMasterEncryptionKey()).toBe('test-key');
    expect(await config.hasOnboardedKey()).toBe(true);
    expect(await config.getThrottle()).toEqual({ bytesPerSec: 1024, quietHours: '22:00-06:00' });
    await expect(
      db
        .insertInto('futo_backups_config')
        .values({ key: ConfigurationKey.OnboardedKey, value: { isOnboarded: false } })
        .execute(),
    ).rejects.toThrow();
  });

  it('allows several paths per repository, prevents duplicate links and cascades dependent state', async () => {
    const backend = await db
      .insertInto('futo_backups_backends')
      .values({ configuration: { type: BackendType.Local, path: '/test-cascade' } })
      .returningAll()
      .executeTakeFirstOrThrow();
    const repository = await db
      .insertInto('futo_backups_repositories')
      .values({ backendId: backend.id, remoteId: 'cascade-repository' })
      .returningAll()
      .executeTakeFirstOrThrow();
    const schedule = await db
      .insertInto('futo_backups_schedule')
      .values({ name: 'Cascade', cron: '0 0 * * *' })
      .returningAll()
      .executeTakeFirstOrThrow();
    expect(schedule.ordering).toEqual([]);

    const paths = new RepositoryPathRepository(db);
    await paths.create({ repositoryId: repository.id, path: '/one' });
    await paths.create({ repositoryId: repository.id, path: '/two' });
    expect(await paths.get(repository.id)).toEqual(expect.arrayContaining(['/one', '/two']));
    expect(await paths.getAll()).toContainEqual({ repositoryId: repository.id, path: '/one' });
    await expect(paths.create({ repositoryId: repository.id, path: '/one' })).rejects.toThrow();
    await paths.delete(repository.id, '/two');
    expect(await paths.get(repository.id)).toEqual(['/one']);

    const schedules = new ScheduleRepository(db);
    await schedules.addRepositoryToSchedule(schedule.id, repository.id);
    expect(await schedules.getRepositoryIds(schedule.id)).toEqual([repository.id]);
    await expect(schedules.addRepositoryToSchedule(schedule.id, repository.id)).rejects.toThrow();
    await schedules.removeRepositoryFromSchedule(schedule.id, repository.id);
    expect(await schedules.getRepositoryIds(schedule.id)).toEqual([]);
    await schedules.addRepositoryToSchedule(schedule.id, repository.id);
    const localMetrics = new RepositoryLocalMetricsRepository(db);
    expect(await localMetrics.get(repository.id)).toEqual({ sizeBytes: 0 });
    expect(await localMetrics.save(repository.id, { sizeBytes: 0 })).toStrictEqual({
      sizeBytes: 0,
      lastBackup: undefined,
      lastBackupStatus: null,
      lastBackupDuration: null,
    });
    const integration = new RepositoryIntegrationImmichRepository(db);
    const configuration = { dataFolders: ['upload'], backupConfiguration: true, libraries: ['all'] };
    await integration.upsert(repository.id, schedule.id, configuration);
    expect(await integration.get()).toEqual({ id: repository.id, scheduleId: schedule.id, configuration });
    await integration.upsert(repository.id, schedule.id, { ...configuration, backupConfiguration: false });
    expect(await integration.get()).toMatchObject({ configuration: { backupConfiguration: false } });
    await integration.delete();
    expect(await integration.get()).toBeUndefined();
    await integration.upsert(repository.id, schedule.id, configuration);
    await expect(db.deleteFrom('futo_backups_backends').where('id', '=', backend.id).execute()).rejects.toThrow();

    await db.deleteFrom('futo_backups_repositories').where('id', '=', repository.id).execute();
    expect(
      await db
        .selectFrom('futo_backups_repository_path')
        .selectAll()
        .where('repositoryId', '=', repository.id)
        .execute(),
    ).toEqual([]);
    expect(
      await db
        .selectFrom('futo_backups_repository_schedule')
        .selectAll()
        .where('repositoryId', '=', repository.id)
        .execute(),
    ).toEqual([]);
    expect(
      await db.selectFrom('futo_backups_local_metrics').selectAll().where('repositoryId', '=', repository.id).execute(),
    ).toEqual([]);
    expect(
      await db
        .selectFrom('futo_backups_integrations_immich_config')
        .selectAll()
        .where('repositoryId', '=', repository.id)
        .execute(),
    ).toEqual([]);
  });

  it('returns schedule repositories in their saved order with ISO timestamps', async () => {
    const backend = await db
      .insertInto('futo_backups_backends')
      .values({ configuration: { type: BackendType.Local, path: '/test-ordering' } })
      .returningAll()
      .executeTakeFirstOrThrow();
    const [first, second] = await db
      .insertInto('futo_backups_repositories')
      .values([
        { backendId: backend.id, remoteId: 'ordering-first' },
        { backendId: backend.id, remoteId: 'ordering-second' },
      ])
      .returning('id')
      .execute();

    const schedules = new ScheduleRepository(db);
    const lastRun = new Date('2026-10-28T09:00:00.000Z');
    const { id } = await schedules.create({ name: 'Ordered', cron: '0 0 * * *', paused: true, lastRun });
    await schedules.addRepositoryToSchedule(id, first.id);
    await schedules.addRepositoryToSchedule(id, second.id);

    await schedules.updateSchedule(id, { ordering: [second.id, first.id] });
    expect(await schedules.get(id)).toEqual({
      id,
      name: 'Ordered',
      cron: '0 0 * * *',
      paused: true,
      lastRun: lastRun.toISOString(),
      lastFinished: undefined,
      repositories: [second.id, first.id],
    });

    await schedules.updateSchedule(id, { ordering: [first.id, second.id] });
    expect(await schedules.getAll()).toContainEqual(
      expect.objectContaining({ id, repositories: [first.id, second.id] }),
    );
  });

  it('runs queued jobs to completion and lists them newest first', async () => {
    const statePath = await mkdtemp(join(tmpdir(), 'yucca-jobs-'));
    const handlers = Object.values(JobName).map((name) => {
      @Job({ name })
      class Handler {
        async run() {}
      }

      return Handler;
    });
    const jobs = new JobRepository(
      db,
      { getProviders: () => handlers.map((metatype) => ({ metatype, instance: new metatype() })) } as never,
      new Reflector(),
      { hasLock: () => true, get: () => ({ statePath }) } as never,
      new StorageRepository(),
      { publish: () => {} } as never,
      LoggingRepository.create(),
      {} as never,
    );
    jobs.onModuleInit();

    const repositoryId = 'remote-repository-for-jobs';
    const [first, second] = await jobs.queueAll([
      { name: JobName.RepositorySyncMetrics, data: { repositoryId } },
      { name: JobName.RepositoryPrune, data: { repositoryId } },
    ]);
    await expect(jobs.wait(second)).resolves.toMatchObject({ id: second, status: JobStatus.Complete });

    const listed = await jobs.getAll(repositoryId);
    expect(listed.map(({ id }) => id)).toEqual([second, first]);
    expect(listed[0]).toMatchObject({
      status: JobStatus.Complete,
      queuedAt: expect.any(String),
      start: expect.any(String),
      end: expect.any(String),
      outcome: { errors: [] },
    });

    await rm(statePath, { recursive: true });
  });

  it('records jobs for remote repositories and gives tied timestamps a stable insertion order', async () => {
    const queuedAt = new Date('2026-10-27T13:00:00.000Z');
    const job = {
      name: JobName.RepositoryRestoreFromPoint,
      repositoryId: 'remote-repository-without-local-state',
      data: {
        repositoryId: 'remote-repository-without-local-state',
        snapshotId: 'snapshot',
        backendId: 'backend',
        options: {},
      },
      status: JobStatus.Queued,
      queuedAt,
      logFilePath: 'logs/jobs/test.jsonl',
    };
    const first = await db.insertInto('futo_backups_jobs').values(job).returningAll().executeTakeFirstOrThrow();
    const second = await db.insertInto('futo_backups_jobs').values(job).returningAll().executeTakeFirstOrThrow();
    expect(first.data).toEqual(job.data);
    expect(first.outcome).toBeNull();
    expect(first.start).toBeNull();
    expect(first.end).toBeNull();
    expect(first.queuedAt).toEqual(queuedAt);
    const jobs = await db
      .selectFrom('futo_backups_jobs')
      .select('id')
      .where('repositoryId', '=', job.repositoryId)
      .orderBy('sequence')
      .execute();
    expect(jobs.map(({ id }) => id)).toEqual([first.id, second.id]);
  });
});
