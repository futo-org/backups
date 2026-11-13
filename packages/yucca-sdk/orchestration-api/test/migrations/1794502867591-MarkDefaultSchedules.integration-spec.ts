import type { Generated } from 'kysely';
import { MigrationHarness, openBefore } from './harness.js';

type Db = {
  futo_backups_schedule: { id: Generated<string>; name: string; cron: string; paused: boolean };
};

const schedules = [
  { name: 'Daily', cron: '0 3 * * *', migrated: '@daily' },
  { name: 'Weekly', cron: '0 3 * * 0', migrated: '@weekly' },
  { name: 'Monthly', cron: '0 3 1 * *', migrated: '@monthly' },
  { name: 'Custom minute', cron: '1 3 * * *', migrated: '1 3 * * *' },
  { name: 'Custom hour', cron: '0 4 * * *', migrated: '0 4 * * *' },
  { name: 'Custom weekday', cron: '0 3 * * 2', migrated: '0 3 * * 2' },
  { name: 'Custom monthday', cron: '0 3 2 * *', migrated: '0 3 2 * *' },
];

let harness: MigrationHarness<Db>;

beforeEach(async () => {
  harness = await openBefore<Db>('1794502867591-MarkDefaultSchedules');
  await harness.db
    .insertInto('futo_backups_schedule')
    .values(schedules.map(({ name, cron }) => ({ name, cron, paused: true })))
    .execute();
});

afterEach(() => harness.close());

const getSchedules = () => harness.db.selectFrom('futo_backups_schedule').select(['name', 'cron']).execute();

describe('MarkDefaultSchedules', () => {
  it('turns only the exact old defaults into presets', async () => {
    await harness.up();

    expect(await getSchedules()).toEqual(
      expect.arrayContaining(schedules.map(({ name, migrated }) => ({ name, cron: migrated }))),
    );
  });

  it('restores the old defaults when migrating down', async () => {
    await harness.up();
    await harness.migrateTo('1794492929949-InstallationId');

    expect(await getSchedules()).toEqual(expect.arrayContaining(schedules.map(({ name, cron }) => ({ name, cron }))));
  });
});
