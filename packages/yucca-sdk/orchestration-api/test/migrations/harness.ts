import { Kysely } from 'kysely';
import { PGliteDialect } from 'kysely-pglite-dialect';
import { FileMigrationProvider, Migrator, NO_MIGRATIONS } from 'kysely/migration';
import { readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { createPGlite } from '../../src/bin/pglite.js';
import type { DB } from '../../src/schema/index.js';

export type MigrationHarness = {
  db: Kysely<DB>;
  up: () => Promise<void>;
  migrateTo: (name: string) => Promise<void>;
  close: () => Promise<void>;
};

export async function openBefore(name: string): Promise<MigrationHarness> {
  const db = new Kysely<DB>({ dialect: new PGliteDialect(await createPGlite()) });
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
