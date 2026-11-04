import { PGlite } from '@electric-sql/pglite';
import { dataDir } from '@electric-sql/pglite-prepopulatedfs';
import { type DatabaseHooks, LoggingRepository, OrchestrationApiModule } from '@futo-org/backups-orchestrator-api';
import { NestFactory } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import express from 'express';
import { PGliteDialect } from 'kysely-pglite-dialect';
import { ZodValidationPipe } from 'nestjs-zod';
import { existsSync, openAsBlob } from 'node:fs';
import { mkdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { CACHEDIR_TAG_CONTENTS, CACHEDIR_TAG_FILE_NAME, STATE_DUMP_FILE_NAME } from './consts.js';
import { readEnv } from './env.js';

async function bootstrap() {
  const env = readEnv();
  const uiPath = env.uiPath ?? resolve(process.cwd(), 'build');
  const indexHtml = resolve(uiPath, 'index.html');

  await stat(indexHtml);

  await mkdir(env.statePath, { recursive: true });

  if (env.cachePath) {
    await mkdir(env.cachePath, { recursive: true });
  }

  const databasePath = resolve(env.statePath, 'state-pglite');

  let loadDataDir: Blob | undefined;
  if (!existsSync(resolve(databasePath, 'PG_VERSION'))) {
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
      await writeFile(resolve(env.statePath, STATE_DUMP_FILE_NAME), Buffer.from(await dump.arrayBuffer()));
      return STATE_DUMP_FILE_NAME;
    },
    async restore(fileName) {
      const previousDatabasePath = `${databasePath}.previous`;
      const dump = await openAsBlob(resolve(env.statePath, fileName));
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

  const app = await NestFactory.create<NestExpressApplication>(
    OrchestrationApiModule.forRootAsync({
      useFactory: () => ({
        dialect: new PGliteDialect(client),
        statePath: env.statePath,
        cachePath: env.cachePath,
        wellKnownUrl: env.wellKnownUrl,
        requireSession: !env.disableAuth,
        resticWalkConcurrency: env.resticWalkConcurrency,
        databaseHooks,
      }),
    }),
    { forceCloseConnections: true },
  );

  const logger = await app.resolve(LoggingRepository);
  logger.setContext('Bootstrap');

  app.enableShutdownHooks();
  app.useGlobalPipes(new ZodValidationPipe());
  app.setGlobalPrefix('api');

  app.use(
    express.static(uiPath, {
      setHeaders: (response, path) => {
        if (path.includes('/_app/immutable/')) {
          response.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
        }
      },
    }),
  );
  app.use((request: express.Request, response: express.Response, next: express.NextFunction) => {
    if (request.method !== 'GET' || request.path.startsWith('/api') || request.path.startsWith('/_app/')) {
      next();
      return;
    }
    response.sendFile(indexHtml);
  });

  await app.listen(env.port, env.host);

  logger.log(`FUTO Backups listening on http://${env.host}:${env.port}`);
  logger.log(`State directory: ${env.statePath}`);
}

void bootstrap();
