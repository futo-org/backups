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
    async restore(fileName) {
      const previousDatabasePath = `${databasePath}.previous`;
      const dump = await openAsBlob(resolve(statePath, fileName));
      await database.close();
      await rm(previousDatabasePath, { recursive: true, force: true });
      await rename(databasePath, previousDatabasePath);

      try {
        database = await PGlite.create({ dataDir: databasePath, loadDataDir: dump });
      } catch (error) {
        await rm(databasePath, { recursive: true, force: true });
        await rename(previousDatabasePath, databasePath);
        database = await PGlite.create({ dataDir: databasePath });
        throw error;
      }

      await writeFile(resolve(databasePath, CACHEDIR_TAG_FILE_NAME), CACHEDIR_TAG_CONTENTS);
    },
  };

  return { dialect: new PGliteDialect(client), databaseHooks };
}
