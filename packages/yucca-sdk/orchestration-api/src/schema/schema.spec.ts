import { schemaDiff, schemaFromCode } from '@immich/sql-tools';
import { Kysely, sql } from 'kysely';
import { PGliteDialect } from 'kysely-pglite-dialect';
import { createPGlite } from '../bin/pglite.js';
import { BackendType, ConfigurationKey, JobName, JobStatus } from '../enum.js';
import { RepositoryPathRepository } from '../repositories/repositoryPath.repository.js';
import { ScheduleRepository } from '../repositories/schedule.repository.js';
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
  });

  it('stores configuration as JSON strings, booleans and numbers', async () => {
    await db
      .insertInto('futo_backups_config')
      .values([
        { key: ConfigurationKey.EncryptionKey, value: sql<string>`${JSON.stringify('test-key')}::jsonb` },
        { key: ConfigurationKey.OnboardedKey, value: true },
        { key: ConfigurationKey.ThrottleBytesPerSec, value: 1024 },
      ])
      .execute();

    const values = await db.selectFrom('futo_backups_config').selectAll().execute();
    expect(Object.fromEntries(values.map(({ key, value }) => [key, value]))).toEqual({
      [ConfigurationKey.EncryptionKey]: 'test-key',
      [ConfigurationKey.OnboardedKey]: true,
      [ConfigurationKey.ThrottleBytesPerSec]: 1024,
    });
    await expect(
      db.insertInto('futo_backups_config').values({ key: ConfigurationKey.OnboardedKey, value: false }).execute(),
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
    await db.insertInto('futo_backups_local_metrics').values({ repositoryId: repository.id }).execute();
    await db
      .insertInto('futo_backups_integrations_immich_config')
      .values({
        repositoryId: repository.id,
        scheduleId: schedule.id,
        configuration: { dataFolders: ['upload'], backupConfiguration: true, libraries: ['all'] },
      })
      .execute();
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
    const jobs = await db.selectFrom('futo_backups_jobs').select('id').orderBy('sequence').execute();
    expect(jobs.map(({ id }) => id)).toEqual([first.id, second.id]);
  });
});
