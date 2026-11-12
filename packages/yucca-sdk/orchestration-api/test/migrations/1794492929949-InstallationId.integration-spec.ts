import { sql } from 'kysely';
import { MigrationHarness, openBefore } from './harness.js';

let harness: MigrationHarness;

beforeEach(async () => {
  harness = await openBefore('1794492929949-InstallationId');
});

afterEach(() => harness.close());

const insertConfig = (key: string) =>
  sql`INSERT INTO "futo_backups_config" ("key", "value") VALUES (${key}, '{}')`.execute(harness.db);

describe('InstallationId', () => {
  it('accepts the installation-id configuration key', async () => {
    await harness.up();

    await expect(insertConfig('installation-id')).resolves.toBeDefined();
  });

  it('removes stored installation ids and keeps other configuration when migrating down', async () => {
    await harness.up();
    await insertConfig('installation-id');
    await insertConfig('telemetry');

    await harness.migrateTo('1793295581871-InitialMigration');

    expect(await harness.db.selectFrom('futo_backups_config').select('key').execute()).toEqual([{ key: 'telemetry' }]);
    await expect(insertConfig('installation-id')).rejects.toThrow();
  });
});
