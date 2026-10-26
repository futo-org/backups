import { MigrationHarness, openBefore } from './harness.js';

let harness: MigrationHarness;

beforeEach(async () => {
  harness = await openBefore('20261013120000-AddJobs');
  harness.database.exec(`INSERT INTO backends (id, configuration) VALUES ('backend', '{}')`);
  harness.database.exec(`INSERT INTO repositories (id, backendId) VALUES ('repository', 'backend')`);
});

afterEach(() => harness.close());

const insertCancelledRun = (id: string) =>
  harness.database
    .prepare(`INSERT INTO runHistory (id, repositoryId, status) VALUES (?, 'repository', 'cancelled')`)
    .run(id);

const insertCancelledMetrics = () =>
  harness.database
    .prepare(`INSERT INTO repositoryLocalMetrics (id, lastBackupStatus) VALUES ('repository', 'cancelled')`)
    .run();

describe('AllowCancelledStatus', () => {
  it('rewrites cancelled statuses as failed when migrating down', async () => {
    insertCancelledRun('run');
    insertCancelledMetrics();

    await harness.migrateTo('20260814120100-AddLastBackupStatus');

    expect(harness.database.prepare(`SELECT id, status FROM runHistory`).all()).toEqual([
      { id: 'run', status: 'failed' },
    ]);
    expect(harness.database.prepare(`SELECT id, lastBackupStatus FROM repositoryLocalMetrics`).all()).toEqual([
      { id: 'repository', lastBackupStatus: 'failed' },
    ]);
  });

  it('rejects cancelled statuses after migrating down', async () => {
    await harness.migrateTo('20260814120100-AddLastBackupStatus');

    expect(() => insertCancelledRun('run')).toThrow(/CHECK constraint failed/);
    expect(() => insertCancelledMetrics()).toThrow(/CHECK constraint failed/);
  });
});
