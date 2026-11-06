import Database from 'better-sqlite3';
import { Kysely, SqliteDialect } from 'kysely';
import { FileMigrationProvider, Migrator } from 'kysely/migration';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openLegacyStateDatabase } from './legacySqlite.js';

let directory: string;
let path: string;

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'legacy-sqlite-'));
  path = join(directory, 'state.sqlite3');
});

afterEach(() => rm(directory, { recursive: true, force: true }));

const createStateDatabaseAt = async (migration: string) => {
  const db = new Kysely<unknown>({ dialect: new SqliteDialect({ database: new Database(path) }) });
  const migrator = new Migrator({
    db,
    migrationLockTableName: 'kysely_migrations_lock',
    migrationTableName: 'kysely_migrations',
    provider: new FileMigrationProvider({
      fs: { readdir },
      path: { join },
      migrationFolder: join(import.meta.dirname, 'migrations'),
    }),
  });

  const { error } = await migrator.migrateTo(migration);
  await db.destroy();
  if (error) {
    throw error;
  }
};

describe('openLegacyStateDatabase', () => {
  it('brings an older state database up to the latest legacy schema and reads its rows', async () => {
    await createStateDatabaseAt('20261013120000-AddJobs');
    const database = new Database(path);
    database.exec(`INSERT INTO backends (id, configuration) VALUES ('backend', '{}')`);
    database.exec(`INSERT INTO repositories (id, backendId) VALUES ('repository', 'backend')`);
    database.close();

    const db = await openLegacyStateDatabase(path);

    const repositories = await db.selectFrom('repositories').select(['id', 'backendId']).execute();
    const tables = await db.introspection.getTables();
    await db.destroy();

    expect(repositories).toEqual([{ id: 'repository', backendId: 'backend' }]);
    expect(tables.map(({ name }) => name)).not.toContain('runHistory');
  });

  it('refuses a SQLite file that was not created by the app', async () => {
    const database = new Database(path);
    database.exec('CREATE TABLE notes (body TEXT)');
    database.close();

    await expect(openLegacyStateDatabase(path)).rejects.toThrow(
      "Refusing to open legacy state database, doesn't appear to be from the app",
    );
  });

  it('refuses a path with no file', async () => {
    await expect(openLegacyStateDatabase(path)).rejects.toMatchObject({ message: 'unable to open database file' });
  });
});
