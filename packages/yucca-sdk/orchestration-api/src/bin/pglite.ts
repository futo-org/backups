import { PGlite } from '@electric-sql/pglite';
import { dataDir } from '@electric-sql/pglite-prepopulatedfs';
import { PGLiteSocketServer } from '@electric-sql/pglite-socket';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export async function createPGlite(databasePath?: string): Promise<PGlite> {
  let loadDataDir: Blob | undefined;
  if (!databasePath || !existsSync(join(databasePath, 'PG_VERSION'))) {
    loadDataDir = await dataDir();
  }

  return PGlite.create({ dataDir: databasePath, loadDataDir });
}

if (import.meta.main) {
  const database = await createPGlite(join(tmpdir(), 'yucca-migrations-pglite'));
  const server = new PGLiteSocketServer({
    db: database,
    host: '127.0.0.1',
    port: 0,
    maxConnections: 10,
  });

  try {
    await server.start();
    console.log(`postgresql://postgres@${server.getServerConn()}/postgres`);

    await new Promise<void>((resolve) => {
      process.once('SIGINT', resolve);
      process.once('SIGTERM', resolve);
    });
  } finally {
    await server.stop();
    await database.close();
  }
}
