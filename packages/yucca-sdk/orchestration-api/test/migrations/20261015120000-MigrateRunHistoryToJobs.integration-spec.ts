import { MigrationHarness, openBefore } from './harness.js';

let harness: MigrationHarness;

beforeEach(async () => {
  harness = await openBefore('20261015120000-MigrateRunHistoryToJobs');
  harness.database.exec(`INSERT INTO backends (id, configuration) VALUES ('backend', '{}')`);
  harness.database.exec(`INSERT INTO repositories (id, backendId) VALUES ('repository', 'backend')`);
});

afterEach(() => harness.close());

const insertRun = (id: string, type: string, status: string | null, logFilePath: string | null) =>
  harness.database
    .prepare(
      `INSERT INTO runHistory (id, repositoryId, start, end, logFilePath, status, type)
        VALUES (?, 'repository', '2026-01-01T00:00:00.000Z', '2026-01-01T00:05:00.000Z', ?, ?, ?)`,
    )
    .run(id, logFilePath, status, type);

const jobs = () =>
  harness.database
    .prepare(`SELECT id, name, repositoryId, data, status, logFilePath, queuedAt, start, end FROM jobs ORDER BY id`)
    .all();

describe('MigrateRunHistoryToJobs', () => {
  it('moves each run into jobs under its job name', async () => {
    insertRun('backup', 'backup', 'complete', '/old/state/logs/repository/2026-01-01T00:00:00.000Z.jsonl');
    insertRun('forget', 'forget', 'warn', '/old/state/logs/repository/forget.jsonl');
    insertRun('restore', 'restore', 'failed', '/old/state/logs/repository/restore.jsonl');

    await harness.up();

    expect(jobs()).toEqual([
      {
        id: 'backup',
        name: 'repository-backup',
        repositoryId: 'repository',
        data: '{"repositoryId":"repository"}',
        status: 'complete',
        logFilePath: 'logs/repository/2026-01-01T00:00:00.000Z.jsonl',
        queuedAt: '2026-01-01T00:00:00.000Z',
        start: '2026-01-01T00:00:00.000Z',
        end: '2026-01-01T00:05:00.000Z',
      },
      expect.objectContaining({ id: 'forget', name: 'repository-prune', status: 'warn' }),
      expect.objectContaining({ id: 'restore', name: 'repository-restore', status: 'failed' }),
    ]);
  });

  it('keeps log paths relative to the state directory, whatever it used to be', async () => {
    insertRun('backup', 'backup', 'complete', '/var/lib/old-state/logs/repository/run.jsonl');

    await harness.up();

    expect(jobs()).toEqual([expect.objectContaining({ logFilePath: 'logs/repository/run.jsonl' })]);
  });

  it('hands an interrupted backup to startup reconciliation and keeps other interrupted runs incomplete', async () => {
    insertRun('interrupted', 'backup', 'incomplete', '/old/state/logs/repository/run.jsonl');
    insertRun('interrupted-restore', 'restore', 'incomplete', '/old/state/logs/repository/restore.jsonl');

    await harness.up();

    expect(jobs()).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ id: 'interrupted', status: 'running' }),
        expect.objectContaining({ id: 'interrupted-restore', status: 'incomplete' }),
      ]),
    );
  });
});
