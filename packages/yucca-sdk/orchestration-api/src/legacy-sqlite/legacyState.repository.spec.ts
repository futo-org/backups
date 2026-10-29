import Database from 'better-sqlite3';
import { Kysely, SqliteDialect } from 'kysely';
import { PGliteDialect } from 'kysely-pglite-dialect';
import { FileMigrationProvider, Migrator } from 'kysely/migration';
import { existsSync } from 'node:fs';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createPGlite } from '../bin/pglite.js';
import { ConfigurationKey } from '../enum.js';
import { DatabaseRepository } from '../repositories/database.repository.js';
import { LoggingRepository } from '../repositories/logging.repository.js';
import { StorageRepository } from '../repositories/storage.repository.js';
import type { DB } from '../schema/index.js';
import { LegacyStateRepository } from './legacyState.repository.js';

const backendId = 'd0368cdd-39ae-40e1-91d6-d81815c65c7e';
const repositoryId = '4b7c1a52-8f53-4f7e-9b8e-2f0c6a1d3e91';
const scheduleId = '9e2d4c1b-5a6f-4e3d-8c7b-1a2b3c4d5e6f';

let directory: string;
let db: Kysely<DB>;
let legacyState: LegacyStateRepository;

const createLegacyState = async (statements: string[], migration?: string) => {
  const legacy = new Kysely<unknown>({
    dialect: new SqliteDialect({ database: new Database(join(directory, 'state.sqlite3')) }),
  });
  const migrator = new Migrator({
    db: legacy,
    migrationLockTableName: 'kysely_migrations_lock',
    migrationTableName: 'kysely_migrations',
    provider: new FileMigrationProvider({
      fs: { readdir },
      path: { join },
      migrationFolder: join(import.meta.dirname, 'migrations'),
    }),
  });

  const { error } = await (migration ? migrator.migrateTo(migration) : migrator.migrateToLatest());
  await legacy.destroy();
  if (error) {
    throw error;
  }

  const database = new Database(join(directory, 'state.sqlite3'));
  for (const statement of statements) {
    database.exec(statement);
  }

  database.close();
};

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'legacy-state-'));
  const database = await createPGlite();
  db = new Kysely<DB>({ dialect: new PGliteDialect(database) });
  await new DatabaseRepository(db, new StorageRepository(), LoggingRepository.create()).runMigrations();
  legacyState = new LegacyStateRepository(db, LoggingRepository.create());
});

afterEach(async () => {
  await db.destroy();
  await rm(directory, { recursive: true, force: true });
});

describe(LegacyStateRepository.name, () => {
  it('imports the key configuration and leaves history and secrets behind', async () => {
    await createLegacyState([
      `INSERT INTO config (key, value) VALUES
        ('encryption-key', 'abc123'),
        ('onboarded-key', '1'),
        ('telemetry', 'full'),
        ('session-secret', 'secret'),
        ('state-path', '/old/state')`,
      `INSERT INTO backends (id, configuration) VALUES ('${backendId}', '{"type":"local","path":"/backups"}')`,
      `INSERT INTO repositories (id, remoteId, backendId, retentionPolicy) VALUES
        ('${repositoryId}', 'remote-uuid', '${backendId}', '{"keepLast":3}'),
        ('my-bucket', 'my-bucket', '${backendId}', NULL)`,
      `INSERT INTO repositoryPaths (id, path) VALUES ('${repositoryId}', '/photos'), ('my-bucket', '/documents')`,
      `INSERT INTO schedules (id, name, paused, cron, ordering) VALUES
        ('${scheduleId}', 'Daily', 1, '0 0 * * *', '["my-bucket","${repositoryId}"]')`,
      `INSERT INTO repositorySchedules (schedule, repository) VALUES ('${scheduleId}', '${repositoryId}'), ('${scheduleId}', 'my-bucket')`,
      `INSERT INTO repositoryIntegrationImmich (id, scheduleId, configuration) VALUES
        ('${repositoryId}', '${scheduleId}', '{"dataFolders":["upload"],"backupConfiguration":true,"libraries":"all"}')`,
      `INSERT INTO repositoryLocalMetrics (id, sizeBytes) VALUES ('${repositoryId}', 42)`,
    ]);

    await legacyState.importFrom(directory);

    const config = await db.selectFrom('futo_backups_config').selectAll().execute();
    expect(Object.fromEntries(config.map(({ key, value }) => [key, value]))).toEqual({
      [ConfigurationKey.EncryptionKey]: { key: 'abc123' },
      [ConfigurationKey.OnboardedKey]: { isOnboarded: true },
      [ConfigurationKey.Telemetry]: { level: 'full' },
    });

    const repositories = await db.selectFrom('futo_backups_repositories').selectAll().execute();
    const bucket = repositories.find(({ remoteId }) => remoteId === 'my-bucket');
    expect(repositories).toHaveLength(2);
    expect(repositories).toContainEqual(
      expect.objectContaining({ id: repositoryId, retentionPolicy: { keepLast: 3 } }),
    );
    expect(bucket?.id).toMatch(/^[\da-f-]{36}$/);

    const paths = await db.selectFrom('futo_backups_repository_path').selectAll().execute();
    expect(paths).toEqual(
      expect.arrayContaining([
        { repositoryId, path: '/photos' },
        { repositoryId: bucket?.id, path: '/documents' },
      ]),
    );

    const [schedule] = await db.selectFrom('futo_backups_schedule').selectAll().execute();
    expect(schedule).toMatchObject({ id: scheduleId, paused: true, ordering: [bucket?.id, repositoryId] });
    const links = await db.selectFrom('futo_backups_repository_schedule').selectAll().execute();
    expect(links).toHaveLength(2);

    const [integration] = await db.selectFrom('futo_backups_integrations_immich_config').selectAll().execute();
    expect(integration).toEqual({
      repositoryId,
      scheduleId,
      configuration: { dataFolders: ['upload'], backupConfiguration: true, libraries: ['all'] },
    });

    const metrics = await db.selectFrom('futo_backups_local_metrics').selectAll().execute();
    expect(metrics).toEqual([]);
    expect(existsSync(join(directory, 'state.sqlite3'))).toBe(false);
    expect(existsSync(join(directory, 'state.sqlite3.imported'))).toBe(true);
  });

  it('upgrades a state database from before remote ids and imports it', async () => {
    await createLegacyState(
      [
        `INSERT INTO config (key, value) VALUES ('encryption-key', 'abc123'), ('onboarded-key', '1')`,
        `INSERT INTO backends (id, configuration) VALUES ('${backendId}', '{"type":"s3","endpoint":"https://s3.test","region":"eu","accessKeyId":"id","secretAccessKey":"secret"}')`,
        `INSERT INTO repositories (id, backendId) VALUES ('my-bucket', '${backendId}')`,
        `INSERT INTO repositoryPaths (id, path) VALUES ('my-bucket', '/photos'), ('my-bucket', '/documents')`,
        `INSERT INTO runHistory (id, repositoryId, start, "end", logFilePath, status)
          VALUES ('run', 'my-bucket', '2026-03-01T00:00:00.000Z', '2026-03-01T01:00:00.000Z', 'logs/run.log', 'complete')`,
        `INSERT INTO repositoryLocalMetrics (id, sizeBytes, lastBackup) VALUES ('my-bucket', 42, '2026-03-01T01:00:00.000Z')`,
        `INSERT INTO schedules (id, name, paused, cron, ordering) VALUES ('${scheduleId}', 'Nightly', 0, '0 3 * * *', '["my-bucket"]')`,
        `INSERT INTO repositorySchedules (repository, schedule) VALUES ('my-bucket', '${scheduleId}')`,
        `INSERT INTO repositoryIntegrationImmich (id, scheduleId, configuration)
          VALUES ('my-bucket', '${scheduleId}', '{"dataFolders":["upload"],"backupConfiguration":false,"libraries":"all"}')`,
      ],
      '20260330130000-AddScheduleIdToImmichIntegration',
    );

    await legacyState.importFrom(directory);

    const [repository] = await db.selectFrom('futo_backups_repositories').selectAll().execute();
    expect(repository).toMatchObject({
      remoteId: 'my-bucket',
      backendId,
      retentionPolicy: null,
      siteCode: null,
      storageClusterCode: null,
    });
    expect(repository.id).toMatch(/^[\da-f-]{36}$/);

    const paths = await db.selectFrom('futo_backups_repository_path').select(['repositoryId', 'path']).execute();
    expect(paths).toEqual(
      expect.arrayContaining([
        { repositoryId: repository.id, path: '/photos' },
        { repositoryId: repository.id, path: '/documents' },
      ]),
    );

    const [schedule] = await db.selectFrom('futo_backups_schedule').selectAll().execute();
    expect(schedule).toMatchObject({ id: scheduleId, name: 'Nightly', paused: false, ordering: [repository.id] });
    const links = await db.selectFrom('futo_backups_repository_schedule').selectAll().execute();
    expect(links).toEqual([{ scheduleId, repositoryId: repository.id }]);

    const [integration] = await db.selectFrom('futo_backups_integrations_immich_config').selectAll().execute();
    expect(integration).toMatchObject({ repositoryId: repository.id, configuration: { libraries: ['all'] } });

    const [backend] = await db.selectFrom('futo_backups_backends').selectAll().execute();
    expect(backend.configuration).toMatchObject({ type: 's3', endpoint: 'https://s3.test' });

    const metrics = await db.selectFrom('futo_backups_local_metrics').selectAll().execute();
    const jobs = await db.selectFrom('futo_backups_jobs').selectAll().execute();
    expect(metrics).toEqual([]);
    expect(jobs).toEqual([]);
  });

  it('does nothing when there is no legacy state database', async () => {
    await legacyState.importFrom(directory);

    const config = await db.selectFrom('futo_backups_config').selectAll().execute();
    expect(config).toEqual([]);
  });
});
