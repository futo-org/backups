import { Kysely } from 'kysely';
import { PGliteDialect } from 'kysely-pglite-dialect';
import { FileMigrationProvider, Migrator, NO_MIGRATIONS } from 'kysely/migration';
import { readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { createPGlite } from '../../src/bin/pglite.js';

export type MigrationHarness<Db> = {
  db: Kysely<Db>;
  up: () => Promise<void>;
  migrateTo: (name: string) => Promise<void>;
  close: () => Promise<void>;
};

export async function openBefore<Db>(name: string): Promise<MigrationHarness<Db>> {
  const db = new Kysely<Db>({ dialect: new PGliteDialect(await createPGlite()) });
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

  return { db, up: () => migrateTo(name), migrateTo, close: () => db.destroy() };
}
