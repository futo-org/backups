import Database from 'better-sqlite3';
import { FileMigrationProvider, Kysely, Migrator, SqliteDialect } from 'kysely';
import { mkdtemp, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ConfigRepository } from '../src/repositories/config.repository.js';
import { DatabaseRepository } from '../src/repositories/database.repository.js';
import { RepositoryService } from '../src/services/repository.service.js';
import { ScheduleService } from '../src/services/schedule.service.js';
import { createTestingModule, TestContext } from './testUtils.js';

let ctx: TestContext;

beforeAll(async () => {
  ctx = await createTestingModule();
}, 15_000);

afterAll(async () => {
  await ctx.app.close();
});

describe('Database', () => {
  it('restores tables from another database', async () => {
    const repositoryService = ctx.module.get(RepositoryService);
    const scheduleService = ctx.module.get(ScheduleService);
    const databaseRepository = ctx.module.get(DatabaseRepository);
    const configRepository = ctx.module.get(ConfigRepository);

    const { repository } = await repositoryService.createRepository(
      { name: 'Snapshot Repo', worm: false },
      ctx.backendId,
    );

    const { schedule } = await scheduleService.createSchedule({
      name: 'Snapshot Schedule',
      paused: false,
      cron: '0 0 * * *',
      repositories: [repository.id],
    });

    const keyBeforeRestore = await configRepository.getMasterEncryptionKey();

    const restoreDir = await mkdtemp(join(tmpdir(), 'yucca-restore-'));
    const snapshotPath = join(restoreDir, 'state.sqlite3');
    await ctx.database.backup(snapshotPath);

    await scheduleService.createSchedule({
      name: 'Post-Snapshot Schedule',
      paused: false,
      cron: '0 6 * * *',
      repositories: [],
    });
    await configRepository.importEncryptionKey('modified-key-after-snapshot');

    const { schedules: beforeRestore } = await scheduleService.getSchedules();
    expect(beforeRestore.find((entry) => entry.name === 'Post-Snapshot Schedule')).toBeDefined();
    expect(await configRepository.getMasterEncryptionKey()).toBe('modified-key-after-snapshot');

    await databaseRepository.restoreFrom(snapshotPath);

    const { schedules: afterRestore } = await scheduleService.getSchedules();
    expect(afterRestore.find((entry) => entry.name === 'Post-Snapshot Schedule')).toBeUndefined();
    expect(afterRestore.find((entry) => entry.id === schedule.id)).toBeDefined();
    expect(await configRepository.getMasterEncryptionKey()).toBe(keyBeforeRestore);
  });

  it('correctly migrates from an older version', async () => {
    const databaseRepository = ctx.module.get(DatabaseRepository);

    const restoreDir = await mkdtemp(join(tmpdir(), 'yucca-restore-'));
    const databasePath = join(restoreDir, 'state.sqlite3');

    const db = new Kysely<unknown>({ dialect: new SqliteDialect({ database: new Database(databasePath) }) });
    const migrator = new Migrator({
      db,
      migrationLockTableName: 'kysely_migrations_lock',
      migrationTableName: 'kysely_migrations',
      provider: new FileMigrationProvider({
        fs: { readdir },
        path: { join },
        migrationFolder: join(import.meta.dirname, '..', 'src', 'schema', 'migrations'),
      }),
    });

    await expect(migrator.migrateTo('20260218105210-InitialMigration')).resolves.toEqual({
      error: undefined,
      results: expect.any(Array),
    });

    await db.destroy();

    await databaseRepository.restoreFrom(databasePath);

    const tables = ctx.database
      .prepare(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`)
      .all() as { name: string }[];

    expect(tables.map((table) => table.name)).toEqual(expect.arrayContaining(['config', 'repositories', 'jobs']));
    expect(ctx.database.prepare('SELECT COUNT(*) AS count FROM repositories').get()).toEqual({ count: 0 });
  });
});
