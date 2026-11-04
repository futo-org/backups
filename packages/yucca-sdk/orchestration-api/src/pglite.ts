import type { PGlite } from '@electric-sql/pglite';
import { existsSync, openAsBlob } from 'node:fs';
import { rename, rm, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import type { DatabaseHooks } from './moduleConfig.js';

const CACHEDIR_TAG_FILE_NAME = 'CACHEDIR.TAG';
const CACHEDIR_TAG_CONTENTS = 'Signature: 8a477f597d28d172789f06886806bc55\n';
const STATE_DUMP_FILE_NAME = 'state.dump';

export async function createPGliteDatabase(databasePath: string, statePath: string) {
  const { PGlite } = await import('@electric-sql/pglite');
  const { PGliteDialect } = await import('kysely-pglite-dialect');
  const nextDatabasePath = `${databasePath}.next`;
  const previousDatabasePath = `${databasePath}.previous`;

  if (!existsSync(databasePath) && existsSync(previousDatabasePath)) {
    await rename(previousDatabasePath, databasePath);
  }

  let loadDataDir: Blob | undefined;
  if (!existsSync(resolve(databasePath, 'PG_VERSION'))) {
    const { dataDir } = await import('@electric-sql/pglite-prepopulatedfs');
    loadDataDir = await dataDir();
  }

  let database = await PGlite.create({ dataDir: databasePath, loadDataDir });
  await writeFile(resolve(databasePath, CACHEDIR_TAG_FILE_NAME), CACHEDIR_TAG_CONTENTS);

  const client = {
    query: (...args: Parameters<PGlite['query']>) => database.query(...args),
    close: () => database.close(),
  } as unknown as PGlite;

  const databaseHooks: DatabaseHooks = {
    tagName: 'yucca.v1.stateDumpFileName',
    async dump() {
      const dump = await database.dumpDataDir('gzip');
      await writeFile(resolve(statePath, STATE_DUMP_FILE_NAME), Buffer.from(await dump.arrayBuffer()));
      return STATE_DUMP_FILE_NAME;
    },
    async cleanup() {
      await rm(resolve(statePath, STATE_DUMP_FILE_NAME), { force: true });
    },
    async restore(fileName) {
      await rm(nextDatabasePath, { recursive: true, force: true });
      await rm(previousDatabasePath, { recursive: true, force: true });

      const dump = await openAsBlob(resolve(statePath, fileName));
      const next = await PGlite.create({ dataDir: nextDatabasePath, loadDataDir: dump });
      await next.close();

      await database.close();
      try {
        await rename(databasePath, previousDatabasePath);
        await rename(nextDatabasePath, databasePath);
      } finally {
        if (!existsSync(databasePath)) {
          await rename(previousDatabasePath, databasePath);
        }

        database = await PGlite.create({ dataDir: databasePath });
      }

      await writeFile(resolve(databasePath, CACHEDIR_TAG_FILE_NAME), CACHEDIR_TAG_CONTENTS);
      await rm(resolve(statePath, fileName), { force: true });
    },
  };

  return { dialect: new PGliteDialect(client), databaseHooks };
}
