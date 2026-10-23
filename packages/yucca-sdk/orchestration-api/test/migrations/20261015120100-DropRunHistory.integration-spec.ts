import { MigrationHarness, openBefore } from './harness.js';

let harness: MigrationHarness;

beforeEach(async () => {
  harness = await openBefore('20261015120100-DropRunHistory');
  harness.database.exec(`INSERT INTO backends (id, configuration) VALUES ('backend', '{}')`);
  harness.database.exec(`INSERT INTO repositories (id, backendId) VALUES ('repository', 'backend')`);
});

afterEach(() => harness.close());

const insertJob = (id: string, logFilePath: string) =>
  harness.database
    .prepare(
      `INSERT INTO jobs (id, name, repositoryId, data, status, logFilePath, queuedAt)
        VALUES (?, 'repository-backup', 'repository', '{}', 'complete', ?, '2026-01-01T00:00:00.000Z')`,
    )
    .run(id, logFilePath);

const runHistoryLogFilePath = (id: string) =>
  (harness.database.prepare(`SELECT logFilePath FROM runHistory WHERE id = ?`).get(id) as { logFilePath: string })
    .logFilePath;

describe('DropRunHistory', () => {
  it('restores absolute log paths under the recorded state directory when rolled back', async () => {
    harness.database.exec(`INSERT INTO config (key, value) VALUES ('state-path', '/var/lib/state')`);
    insertJob('relative', 'logs/repository/run.jsonl');
    insertJob('absolute', '/elsewhere/logs/repository/run.jsonl');
    await harness.up();

    await harness.migrateTo('20261015120000-MigrateRunHistoryToJobs');

    expect(runHistoryLogFilePath('relative')).toBe('/var/lib/state/logs/repository/run.jsonl');
    expect(runHistoryLogFilePath('absolute')).toBe('/elsewhere/logs/repository/run.jsonl');
  });
});
