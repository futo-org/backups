import Database from 'better-sqlite3';
import { Kysely, SqliteDialect } from 'kysely';
import { PGliteDialect } from 'kysely-pglite-dialect';
import { FileMigrationProvider, Migrator } from 'kysely/migration';
import { existsSync } from 'node:fs';
import { mkdtemp, readdir, rename, rm } from 'node:fs/promises';
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
  it('imports the state and history and leaves secrets behind', async () => {
    await createLegacyState([
      `INSERT INTO config (key, value) VALUES
        ('encryption-key', 'abc123'),
        ('onboarded-key', '1'),
        ('telemetry', 'full'),
        ('skipped-onboarding-extra-config', '1'),
        ('ignored-immich-database-dump-warning', '1'),
        ('restic-o-rest-connections', '12'),
        ('support-mode', '{"remainingRuns":2,"streamToFuto":true,"includePaths":false}'),
        ('session-secret', 'secret'),
        ('state-path', '/old/state')`,
      `INSERT INTO backends (id, configuration) VALUES ('${backendId}', '{"type":"local","path":"/backups"}')`,
      `INSERT INTO repositories (id, remoteId, backendId, retentionPolicy, siteCode, storageClusterCode) VALUES
        ('${repositoryId}', 'remote-uuid', '${backendId}', '{"keepLast":3,"keepWithin":"1m"}', 'test-site', 'test-cluster'),
        ('my-bucket', 'my-bucket', '${backendId}', NULL, NULL, NULL)`,
      `INSERT INTO repositoryPaths (id, path) VALUES ('${repositoryId}', '/photos'), ('my-bucket', '/documents')`,
      `INSERT INTO schedules (id, name, paused, cron, ordering, lastRun, lastFinished) VALUES
        ('${scheduleId}', 'Daily', 1, '0 0 * * *', '["my-bucket","${repositoryId}"]', '2026-03-01T00:00:00.000Z', '2026-03-01T01:00:00.000Z')`,
      `INSERT INTO repositorySchedules (schedule, repository) VALUES ('${scheduleId}', '${repositoryId}'), ('${scheduleId}', 'my-bucket')`,
      `INSERT INTO repositoryIntegrationImmich (id, scheduleId, configuration) VALUES
        ('${repositoryId}', '${scheduleId}', '{"dataFolders":["upload"],"backupConfiguration":true,"libraries":"all"}')`,
      `INSERT INTO repositoryLocalMetrics (id, sizeBytes, lastBackup, lastBackupStatus, lastBackupDuration) VALUES
        ('${repositoryId}', 42, '2026-03-01T01:00:00.000Z', 'warn', 3600)`,
      `INSERT INTO jobs (id, name, repositoryId, data, status, outcome, logFilePath, queuedAt, start, "end") VALUES
        ('legacy-job', 'repository-backup', 'my-bucket', '{"repositoryId":"my-bucket"}', 'complete', '{"type":"backup","filesNew":1}', 'logs/jobs/legacy-job.jsonl', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:01.000Z', '2026-03-01T01:00:00.000Z'),
        ('${scheduleId}', 'repository-prune', '${repositoryId}', '{"repositoryId":"${repositoryId}"}', 'running', NULL, 'logs/jobs/prune.jsonl', '2026-03-02T00:00:00.000Z', NULL, NULL)`,
    ]);

    await legacyState.importFrom(directory);

    const config = await db.selectFrom('futo_backups_config').selectAll().execute();
    expect(Object.fromEntries(config.map(({ key, value }) => [key, value]))).toEqual({
      [ConfigurationKey.EncryptionKey]: { key: 'abc123' },
      [ConfigurationKey.OnboardedKey]: { isOnboarded: true },
      [ConfigurationKey.Telemetry]: { level: 'full' },
      [ConfigurationKey.SkippedOnboardingExtraConfig]: { isSkipped: true },
      [ConfigurationKey.IgnoredImmichDatabaseDumpWarning]: { isIgnored: true },
      [ConfigurationKey.ResticOptionRestConnections]: { connections: 12 },
      [ConfigurationKey.SupportMode]: { remainingRuns: 2, streamToFuto: true, includePaths: false },
    });

    const backends = await db.selectFrom('futo_backups_backends').selectAll().execute();
    expect(backends).toEqual([{ id: backendId, configuration: { type: 'local', path: '/backups' } }]);

    const repositories = await db.selectFrom('futo_backups_repositories').selectAll().execute();
    const bucket = repositories.find(({ remoteId }) => remoteId === 'my-bucket');
    expect(repositories).toHaveLength(2);
    expect(repositories).toContainEqual({
      id: repositoryId,
      remoteId: 'remote-uuid',
      backendId,
      retentionPolicy: { keepLast: 3, keepWithin: '1m' },
      siteCode: 'test-site',
      storageClusterCode: 'test-cluster',
    });
    expect(bucket?.id).toMatch(/^[\da-f-]{36}$/);
    expect(bucket).toEqual({
      id: bucket?.id,
      remoteId: 'my-bucket',
      backendId,
      retentionPolicy: null,
      siteCode: null,
      storageClusterCode: null,
    });

    const paths = await db.selectFrom('futo_backups_repository_path').selectAll().execute();
    expect(paths).toEqual(
      expect.arrayContaining([
        { repositoryId, path: '/photos' },
        { repositoryId: bucket?.id, path: '/documents' },
      ]),
    );
    expect(paths).toHaveLength(2);

    const [schedule] = await db.selectFrom('futo_backups_schedule').selectAll().execute();
    expect(schedule).toEqual({
      id: scheduleId,
      name: 'Daily',
      paused: true,
      cron: '0 0 * * *',
      ordering: [bucket?.id, repositoryId],
      lastRun: new Date('2026-03-01T00:00:00.000Z'),
      lastFinished: new Date('2026-03-01T01:00:00.000Z'),
    });
    const links = await db.selectFrom('futo_backups_repository_schedule').selectAll().execute();
    expect(links).toEqual(
      expect.arrayContaining([
        { repositoryId, scheduleId },
        { repositoryId: bucket?.id, scheduleId },
      ]),
    );
    expect(links).toHaveLength(2);

    const [integration] = await db.selectFrom('futo_backups_integrations_immich_config').selectAll().execute();
    expect(integration).toEqual({
      repositoryId,
      scheduleId,
      configuration: { dataFolders: ['upload'], backupConfiguration: true, libraries: ['all'] },
    });

    const metrics = await db.selectFrom('futo_backups_local_metrics').selectAll().execute();
    expect(metrics).toEqual([
      {
        repositoryId,
        sizeBytes: 42,
        lastBackup: new Date('2026-03-01T01:00:00.000Z'),
        lastBackupStatus: 'warn',
        lastBackupDuration: 3600,
      },
    ]);

    const jobs = await db.selectFrom('futo_backups_jobs').selectAll().orderBy('queuedAt').execute();
    expect(jobs).toEqual([
      {
        id: expect.stringMatching(/^[\da-f-]{36}$/),
        sequence: expect.anything(),
        name: 'repository-backup',
        repositoryId: bucket?.id,
        data: { repositoryId: bucket?.id },
        status: 'complete',
        outcome: { type: 'backup', filesNew: 1 },
        logFilePath: 'logs/jobs/legacy-job.jsonl',
        queuedAt: new Date('2026-03-01T00:00:00.000Z'),
        start: new Date('2026-03-01T00:00:01.000Z'),
        end: new Date('2026-03-01T01:00:00.000Z'),
      },
      {
        id: scheduleId,
        sequence: expect.anything(),
        name: 'repository-prune',
        repositoryId,
        data: { repositoryId },
        status: 'running',
        outcome: null,
        logFilePath: 'logs/jobs/prune.jsonl',
        queuedAt: new Date('2026-03-02T00:00:00.000Z'),
        start: null,
        end: null,
      },
    ]);
    expect(existsSync(join(directory, 'state.sqlite3'))).toBe(false);
    expect(existsSync(join(directory, 'state.sqlite3.imported'))).toBe(true);
  });

  it.each([
    { rate: '1234567', quietHours: '01:00-02:00', expected: { bytesPerSec: 1_234_567, quietHours: '01:00-02:00' } },
    { rate: '1234567', quietHours: undefined, expected: { bytesPerSec: 1_234_567 } },
    { rate: '0', quietHours: '', expected: { bytesPerSec: 0 } },
    { rate: undefined, quietHours: '01:00-02:00', expected: undefined },
    { rate: undefined, quietHours: undefined, expected: undefined },
  ])(
    'preserves throttle behaviour for $rate bytes/s and quiet hours $quietHours',
    async ({ rate, quietHours, expected }) => {
      const statements: string[] = [];
      if (rate !== undefined) {
        statements.push(`INSERT INTO config (key, value) VALUES ('throttle-bytes-per-sec', '${rate}')`);
      }

      if (quietHours !== undefined) {
        statements.push(`INSERT INTO config (key, value) VALUES ('throttle-quiet-hours', '${quietHours}')`);
      }

      await createLegacyState(statements);
      await legacyState.importFrom(directory);

      const throttle = await db
        .selectFrom('futo_backups_config')
        .select('value')
        .where('key', '=', ConfigurationKey.Throttle)
        .executeTakeFirst();
      expect(throttle?.value).toEqual(expected);
    },
  );

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
          VALUES ('my-bucket', '${scheduleId}', '{"dataFolders":["upload"],"backupConfiguration":false,"libraries":["library-one","library-two"]}')`,
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
    expect(integration).toEqual({
      repositoryId: repository.id,
      scheduleId,
      configuration: { dataFolders: ['upload'], backupConfiguration: false, libraries: ['library-one', 'library-two'] },
    });

    const [backend] = await db.selectFrom('futo_backups_backends').selectAll().execute();
    expect(backend).toEqual({
      id: backendId,
      configuration: {
        type: 's3',
        endpoint: 'https://s3.test',
        region: 'eu',
        accessKeyId: 'id',
        secretAccessKey: 'secret',
      },
    });

    const metrics = await db.selectFrom('futo_backups_local_metrics').selectAll().execute();
    expect(metrics).toMatchObject([
      { repositoryId: repository.id, sizeBytes: 42, lastBackup: new Date('2026-03-01T01:00:00.000Z') },
    ]);

    const jobs = await db.selectFrom('futo_backups_jobs').selectAll().execute();
    expect(jobs).toMatchObject([
      {
        name: 'repository-backup',
        repositoryId: repository.id,
        data: { repositoryId: repository.id },
        status: 'complete',
        logFilePath: 'logs/my-bucket/run.log',
        queuedAt: new Date('2026-03-01T00:00:00.000Z'),
        end: new Date('2026-03-01T01:00:00.000Z'),
      },
    ]);
  });

  it('schedules an Immich integration from before schedule ids on its linked schedule', async () => {
    await createLegacyState(
      [
        `INSERT INTO backends (id, configuration) VALUES ('${backendId}', '{"type":"local","path":"/backups"}')`,
        `INSERT INTO repositories (id, backendId) VALUES ('${repositoryId}', '${backendId}')`,
        `INSERT INTO schedules (id, name, paused, cron, ordering) VALUES ('${scheduleId}', 'Nightly', 0, '0 3 * * *', '["${repositoryId}"]')`,
        `INSERT INTO repositorySchedules (repository, schedule) VALUES ('${repositoryId}', '${scheduleId}')`,
        `INSERT INTO repositoryIntegrationImmich (id, configuration)
          VALUES ('${repositoryId}', '{"dataFolders":["upload"],"backupConfiguration":true,"libraries":"all"}')`,
      ],
      '20260330120000-RepositoryIntegrationImmichTable',
    );

    await legacyState.importFrom(directory);

    const integrations = await db.selectFrom('futo_backups_integrations_immich_config').selectAll().execute();
    expect(integrations).toEqual([
      {
        repositoryId,
        scheduleId,
        configuration: { dataFolders: ['upload'], backupConfiguration: true, libraries: ['all'] },
      },
    ]);
  });

  it('gives an unscheduled Immich integration from before schedule ids a paused schedule', async () => {
    await createLegacyState(
      [
        `INSERT INTO backends (id, configuration) VALUES ('${backendId}', '{"type":"local","path":"/backups"}')`,
        `INSERT INTO repositories (id, backendId) VALUES ('${repositoryId}', '${backendId}')`,
        `INSERT INTO repositoryIntegrationImmich (id, configuration)
          VALUES ('${repositoryId}', '{"dataFolders":["upload"],"backupConfiguration":true,"libraries":"all"}')`,
      ],
      '20260330120000-RepositoryIntegrationImmichTable',
    );

    await legacyState.importFrom(directory);

    const [schedule] = await db.selectFrom('futo_backups_schedule').selectAll().execute();
    expect(schedule).toMatchObject({ name: 'Immich Backup', paused: true, ordering: [repositoryId] });
    const links = await db.selectFrom('futo_backups_repository_schedule').selectAll().execute();
    expect(links).toEqual([{ repositoryId, scheduleId: schedule.id }]);
    const integrations = await db.selectFrom('futo_backups_integrations_immich_config').selectAll().execute();
    expect(integrations).toMatchObject([{ repositoryId, scheduleId: schedule.id }]);
  });

  it('does nothing when there is no legacy state database', async () => {
    await legacyState.importFrom(directory);

    const config = await db.selectFrom('futo_backups_config').selectAll().execute();
    expect(config).toEqual([]);
  });

  it('preserves cloud backend credentials and does not import the same database twice', async () => {
    const configuration = {
      type: 'yucca',
      url: 'https://backups.test',
      accessToken: 'test-token',
      userId: 'test-user',
    };
    await createLegacyState([
      `INSERT INTO backends (id, configuration) VALUES ('${backendId}', '${JSON.stringify(configuration)}')`,
    ]);

    await legacyState.importFrom(directory);
    await legacyState.importFrom(directory);

    const backends = await db.selectFrom('futo_backups_backends').selectAll().execute();
    expect(backends).toEqual([{ id: backendId, configuration }]);
  });

  it('rolls back imported data and keeps the legacy database when an import fails', async () => {
    await createLegacyState([
      `INSERT INTO config (key, value) VALUES ('encryption-key', 'abc123')`,
      `INSERT INTO backends (id, configuration) VALUES ('${backendId}', '{"type":"local","path":"/backups"}')`,
      `INSERT INTO schedules (id, name, paused, cron, ordering) VALUES ('invalid-uuid', 'Daily', 0, '0 0 * * *', '[]')`,
    ]);

    await expect(legacyState.importFrom(directory)).rejects.toThrow('invalid input syntax for type uuid');

    const config = await db.selectFrom('futo_backups_config').selectAll().execute();
    const backends = await db.selectFrom('futo_backups_backends').selectAll().execute();
    expect(config).toEqual([]);
    expect(backends).toEqual([]);
    expect(existsSync(join(directory, 'state.sqlite3'))).toBe(true);
    expect(existsSync(join(directory, 'state.sqlite3.imported'))).toBe(false);
  });

  it('retries a failed import on the next run', async () => {
    await createLegacyState([
      `INSERT INTO config (key, value) VALUES ('encryption-key', 'abc123')`,
      `INSERT INTO schedules (id, name, paused, cron, ordering) VALUES ('invalid-uuid', 'Daily', 0, '0 0 * * *', '[]')`,
    ]);
    await expect(legacyState.importFrom(directory)).rejects.toThrow('invalid input syntax for type uuid');

    const legacy = new Database(join(directory, 'state.sqlite3'));
    legacy.exec(`UPDATE schedules SET id = '${scheduleId}'`);
    legacy.close();
    await legacyState.importFrom(directory);

    const config = await db.selectFrom('futo_backups_config').selectAll().execute();
    expect(config).toEqual([{ key: ConfigurationKey.EncryptionKey, value: { key: 'abc123' } }]);
    expect(existsSync(join(directory, 'state.sqlite3.imported'))).toBe(true);
  });

  it('does not import again when the legacy database could not be renamed after an import', async () => {
    await createLegacyState([
      `INSERT INTO config (key, value) VALUES ('encryption-key', 'abc123')`,
      `INSERT INTO backends (id, configuration) VALUES ('${backendId}', '{"type":"local","path":"/backups"}')`,
    ]);
    await legacyState.importFrom(directory);
    await rename(join(directory, 'state.sqlite3.imported'), join(directory, 'state.sqlite3'));

    await legacyState.importFrom(directory);

    const backends = await db.selectFrom('futo_backups_backends').selectAll().execute();
    expect(backends).toHaveLength(1);
    expect(existsSync(join(directory, 'state.sqlite3'))).toBe(false);
    expect(existsSync(join(directory, 'state.sqlite3.imported'))).toBe(true);
  });
});
