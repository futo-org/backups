import { MigrationHarness, openBefore } from './harness.js';

type Db = {
  futo_backups_backends: { id: string; configuration: unknown };
  futo_backups_repositories: { id: string; backendId: string; remoteId: string; name: string | null };
};

let harness: MigrationHarness<Db>;

beforeEach(async () => {
  harness = await openBefore<Db>('1794844179560-RepositoryName');
});

afterEach(() => harness.close());

it('keeps existing repositories without a cached name and allows a name to be saved', async () => {
  const backend = await harness.db
    .insertInto('futo_backups_backends')
    .values({ configuration: { type: 'local', path: '/backups' } })
    .returning('id')
    .executeTakeFirstOrThrow();
  const repository = await harness.db
    .insertInto('futo_backups_repositories')
    .values({ backendId: backend.id, remoteId: 'existing-repository' })
    .returning('id')
    .executeTakeFirstOrThrow();

  await harness.up();

  expect(await harness.db.selectFrom('futo_backups_repositories').selectAll().executeTakeFirstOrThrow()).toMatchObject({
    id: repository.id,
    remoteId: 'existing-repository',
    name: null,
  });
  await harness.db
    .updateTable('futo_backups_repositories')
    .set({ name: 'Family Photos' })
    .where('id', '=', repository.id)
    .execute();
  expect(await harness.db.selectFrom('futo_backups_repositories').select('name').executeTakeFirstOrThrow()).toEqual({
    name: 'Family Photos',
  });

  await harness.migrateTo('1794502867591-MarkDefaultSchedules');

  expect(await harness.db.selectFrom('futo_backups_repositories').select(['id', 'remoteId']).execute()).toEqual([
    { id: repository.id, remoteId: 'existing-repository' },
  ]);
});
