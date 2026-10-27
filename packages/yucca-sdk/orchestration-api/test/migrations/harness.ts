import Database from 'better-sqlite3';
import { Kysely, SqliteDialect } from 'kysely';
import { FileMigrationProvider, Migrator, NO_MIGRATIONS } from 'kysely/migration';
import { readdir } from 'node:fs/promises';
import { join } from 'node:path';

export type MigrationHarness = {
  database: InstanceType<typeof Database>;
  up: () => Promise<void>;
  migrateTo: (name: string) => Promise<void>;
  close: () => Promise<void>;
};

export async function openBefore(name: string): Promise<MigrationHarness> {
  const database = new Database(':memory:');
  const db = new Kysely<unknown>({ dialect: new SqliteDialect({ database }) });
  const provider = new FileMigrationProvider({
    fs: { readdir },
    path: { join },
    migrationFolder: join(import.meta.dirname, '..', '..', 'src/schema/migrations'),
  });
  const migrator = new Migrator({ db, provider });

  const names = Object.keys(await provider.getMigrations()).toSorted();
  const index = names.indexOf(name);
  if (index === -1) {
    throw new Error(`Unknown migration ${name}`);
  }

  const migrateTo = async (target: string | typeof NO_MIGRATIONS) => {
    const { error } = await migrator.migrateTo(target);
    if (error) {
      throw error;
    }
  };

  await migrateTo(index === 0 ? NO_MIGRATIONS : names[index - 1]);

  return { database, up: () => migrateTo(name), migrateTo, close: () => db.destroy() };
}
