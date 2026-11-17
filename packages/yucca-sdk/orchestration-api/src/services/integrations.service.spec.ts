import { Reflector } from '@nestjs/core';
import { Kysely } from 'kysely';
import { PGliteDialect } from 'kysely-pglite-dialect';
import { createPGlite } from '../bin/pglite.js';
import { JobName, JobStatus } from '../enum.js';
import { DatabaseRepository } from '../repositories/database.repository.js';
import { JobRepository } from '../repositories/job.repository.js';
import { LoggingRepository } from '../repositories/logging.repository.js';
import { StorageRepository } from '../repositories/storage.repository.js';
import type { DB } from '../schema/index.js';
import { IntegrationsService } from './integrations.service.js';

const repositoryId = 'immich-repository';

const createService = (db: Kysely<DB>) =>
  new IntegrationsService(
    { getBackends: () => ({ backends: [] }), isCloudFeatureEnabled: () => Promise.resolve(false) } as never,
    {} as never,
    { get: () => ({ immichIntegration: { hooks: { getImmichDatabaseDumpConfig: () => {} } } }) } as never,
    { hasIgnoredImmichDatabaseDumpWarning: () => false } as never,
    { get: () => ({ id: repositoryId, scheduleId: 'schedule' }) } as never,
    {} as never,
    { getRepositories: () => ({ repositories: [] }) } as never,
    new JobRepository(
      db,
      {} as never,
      new Reflector(),
      { hasLock: () => false } as never,
      {} as never,
      { publish: () => {} } as never,
      LoggingRepository.create(),
      {} as never,
      {} as never,
      {} as never,
      {} as never,
    ),
    {} as never,
    { get: () => {} } as never,
    {} as never,
    {} as never,
    {} as never,
    {} as never,
    { isAvailable: () => true } as never,
  );

describe(IntegrationsService.name, () => {
  let db: Kysely<DB>;

  beforeAll(async () => {
    const database = await createPGlite();
    db = new Kysely<DB>({ dialect: new PGliteDialect(database) });
    await new DatabaseRepository(db, new StorageRepository(), LoggingRepository.create()).runMigrations();
  }, 30_000);

  afterAll(async () => {
    await db.destroy();
  });

  it('reports the running backup rather than a newer one queued behind it', async () => {
    const [running] = await db
      .insertInto('futo_backups_jobs')
      .values(
        [JobStatus.Running, JobStatus.Queued].map((status) => ({
          name: JobName.RepositoryBackup,
          repositoryId,
          data: { repositoryId },
          status,
          logFilePath: 'logs/jobs/existing.jsonl',
        })),
      )
      .returningAll()
      .execute();

    const { latestBackupJob } = await createService(db).getImmichBackupStatus();

    expect(latestBackupJob).toMatchObject({ id: running.id, status: JobStatus.Running });
  });
});
