import { NestFactory } from '@nestjs/core';
import { ZodValidationPipe } from 'nestjs-zod';
import { LoggingRepository, ORCHESTRATION_PORT, OrchestrationApiModule } from '../index.js';

async function bootstrap() {
  const databaseDumpConfig = { enabled: true, keepLastAmount: 14 };

  const app = await NestFactory.create(
    OrchestrationApiModule.forRootAsync({
      useFactory: () => ({
        wellKnownUrl: process.env.FUTO_BACKUPS_WELL_KNOWN_URL,
        developmentMode: true,
        immichIntegration: {
          dataFolders: ['upload', 'profile', 'library', 'backups', 'thumbs', 'encoded-video'],
          dataPath: '/immich_data',
          libraries: [
            {
              id: 'my-library',
              name: 'my library',
              importPaths: ['/immich_library'],
              exclusionPatterns: [],
            },
          ],
          hooks: {
            createDatabaseBackup() {
              return Promise.resolve('dev-database-backup.sql');
            },
            async cleanupDatabaseBackups() {},
            getImmichDatabaseDumpConfig() {
              return Promise.resolve(databaseDumpConfig);
            },
            configureImmichDatabaseDump(config) {
              Object.assign(databaseDumpConfig, config);
              return Promise.resolve();
            },
            enterMaintenanceRollback(repositoryId, snapshotId, backupFileName) {
              return Promise.resolve({
                jwt: [repositoryId, snapshotId, backupFileName].join(':'),
              });
            },
          },
        },
      }),
    }),
    { forceCloseConnections: true },
  );

  const logger = await app.resolve(LoggingRepository);
  logger.setContext('Bootstrap');

  app.enableShutdownHooks();
  app.enableCors({ origin: 'http://localhost:36066', credentials: true });
  app.useGlobalPipes(new ZodValidationPipe());
  app.setGlobalPrefix('api');
  await app.listen(ORCHESTRATION_PORT, '127.0.0.1');

  logger.log(`Orchestration API listening on http://127.0.0.1:${ORCHESTRATION_PORT}`);
}

void bootstrap();
