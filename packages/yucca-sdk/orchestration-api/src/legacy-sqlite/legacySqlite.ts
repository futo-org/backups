import Database from 'better-sqlite3';
import { Kysely, sql, SqliteDialect } from 'kysely';
import { FileMigrationProvider, Migrator } from 'kysely/migration';
import { readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { LegacyDB } from './schema.js';

export async function openLegacyStateDatabase(path: string): Promise<Kysely<LegacyDB>> {
  const db = new Kysely<LegacyDB>({
    dialect: new SqliteDialect({ database: new Database(path, { fileMustExist: true }) }),
  });

  try {
    const { rows: kyselyProbe } = await sql`
      SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'kysely_migrations'
    `.execute(db);

    if (kyselyProbe.length === 0) {
      throw new Error("Refusing to open legacy state database, doesn't appear to be from the app");
    }

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

    const { error } = await migrator.migrateToLatest();
    if (error) {
      throw error;
    }
  } catch (error) {
    await db.destroy();
    throw error;
  }

  return db;
}
