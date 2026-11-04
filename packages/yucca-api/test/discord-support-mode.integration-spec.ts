import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Kysely, sql } from 'kysely';
import { FileMigrationProvider, Migrator } from 'kysely/migration';
import { randomUUID } from 'node:crypto';
import { readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { DiscordInternalController } from 'src/controllers/discordInternal.controller.js';
import { env } from 'src/env.js';
import { CryptoRepository } from 'src/repositories/crypto.repository.js';
import { DiscordRepository } from 'src/repositories/discord.repository.js';
import { UserRepository } from 'src/repositories/user.repository.js';
import { DB } from 'src/schema/index.js';
import { DiscordService } from 'src/services/discord.service.js';
import { getKyselyConfig } from 'src/utils/database.js';
import request from 'supertest';
import { App } from 'supertest/types.js';

const flag = 'support-log-streaming';

describe('Discord ticket support mode (integration)', () => {
  const schema = `discord_support_mode_${randomUUID().replaceAll('-', '')}`;
  let adminDb: Kysely<DB>;
  let db: Kysely<DB>;
  let app: INestApplication<App>;
  let userId: string;

  const enable = (threadId: string, discordUserId = 'customer-1') =>
    request(app.getHttpServer())
      .put(`/api/internal/discord/support-mode/${threadId}`)
      .set('X-Internal-Secret', env.INTERNAL_SECRET)
      .send({ discordUserId });

  const disable = (threadId: string) =>
    request(app.getHttpServer())
      .delete(`/api/internal/discord/support-mode/${threadId}`)
      .set('X-Internal-Secret', env.INTERNAL_SECRET)
      .expect(204);

  const listTickets = async () => {
    const { body } = await request(app.getHttpServer())
      .get('/api/internal/discord/support-mode')
      .set('X-Internal-Secret', env.INTERNAL_SECRET)
      .expect(200);
    return body as unknown;
  };

  const getOverride = () =>
    db
      .selectFrom('userFeatureFlagOverride')
      .select(['value', 'setBy'])
      .where('userId', '=', userId)
      .where('flag', '=', flag)
      .executeTakeFirst();

  const setByAdmin = (value: boolean) =>
    db
      .insertInto('userFeatureFlagOverride')
      .values({ userId, flag, value, setBy: 'admin-sub', reason: null })
      .onConflict((oc) => oc.columns(['userId', 'flag']).doUpdateSet({ value, setBy: 'admin-sub' }))
      .execute();

  beforeAll(async () => {
    adminDb = new Kysely(getKyselyConfig());
    await sql`CREATE SCHEMA ${sql.id(schema)}`.execute(adminDb);
    db = new Kysely({
      ...getKyselyConfig({ connection: { TimeZone: 'UTC', search_path: schema, application_name: schema } }),
      log: [],
    });
    const migrator = new Migrator({
      db,
      migrationTableSchema: schema,
      migrationTableName: 'kysely_migrations',
      migrationLockTableName: 'kysely_migrations_lock',
      provider: new FileMigrationProvider({
        fs: { readdir },
        path: { join },
        migrationFolder: join(import.meta.dirname, '..', 'src/schema/migrations'),
      }),
    });
    const { error } = await migrator.migrateToLatest();
    if (error) {
      throw error;
    }
    const module = await Test.createTestingModule({
      controllers: [DiscordInternalController],
      providers: [
        { provide: DiscordService, useValue: new DiscordService(new DiscordRepository(db), new CryptoRepository()) },
      ],
    }).compile();
    app = module.createNestApplication();
    app.setGlobalPrefix('/api');
    await app.init();
  }, 30_000);

  beforeEach(async () => {
    await db.deleteFrom('userFeatureFlagOverride').execute();
    await db.deleteFrom('discordLinks').execute();
    await db.deleteFrom('users').execute();
    const user = await new UserRepository(db).create({ sub: 'customer', name: 'Customer', email: 'c@example.test' });
    userId = user.id;
    await new DiscordRepository(db).linkDirect(userId, 'customer-1', 'customer');
  });

  afterAll(async () => {
    await app?.close();
    await db?.destroy();
    await sql`DROP SCHEMA ${sql.id(schema)} CASCADE`.execute(adminDb);
    await adminDb.destroy();
  });

  it('turns support mode on for the ticket and off when that ticket closes', async () => {
    await enable('thread-1').expect(200, { status: 'enabled' });
    expect(await getOverride()).toEqual({ value: true, setBy: 'discord-ticket:thread-1' });

    await disable('thread-1');

    expect(await getOverride()).toBeUndefined();
  });

  it('leaves a grant an admin made in place', async () => {
    await setByAdmin(true);

    await enable('thread-1').expect(200, { status: 'already-enabled' });
    await disable('thread-1');

    expect(await getOverride()).toEqual({ value: true, setBy: 'admin-sub' });
  });

  it('overrides an earlier admin opt-out until the ticket closes', async () => {
    await setByAdmin(false);

    await enable('thread-1').expect(200, { status: 'enabled' });
    expect(await getOverride()).toEqual({ value: true, setBy: 'discord-ticket:thread-1' });
    await disable('thread-1');

    expect(await getOverride()).toBeUndefined();
  });

  it.each([
    ['thread-1', 'thread-2'],
    ['thread-2', 'thread-1'],
  ])('keeps support mode on until both tickets close, %s first', async (first, last) => {
    await enable('thread-1').expect(200, { status: 'enabled' });
    await enable('thread-2').expect(200, { status: 'enabled' });

    await disable(first);
    expect(await getOverride()).toEqual({ value: true, setBy: `discord-ticket:${last}` });
    await expect(listTickets()).resolves.toEqual({ items: [{ threadId: last }] });

    await disable(last);
    expect(await getOverride()).toBeUndefined();
    await expect(listTickets()).resolves.toEqual({ items: [] });
  });

  it('forgets tickets from before an admin opt-out when a ticket turns it back on', async () => {
    await enable('thread-1').expect(200, { status: 'enabled' });
    await setByAdmin(false);
    await enable('thread-2').expect(200, { status: 'enabled' });

    await disable('thread-2');

    expect(await getOverride()).toBeUndefined();
  });

  it.each([true, false])('keeps an admin change to %s made while the ticket was open', async (value) => {
    await enable('thread-1').expect(200, { status: 'enabled' });
    await setByAdmin(value);

    await disable('thread-1');

    expect(await getOverride()).toEqual({ value, setBy: 'admin-sub' });
  });

  it('turns support mode off for every account the ticket granted it to', async () => {
    await enable('thread-1').expect(200, { status: 'enabled' });
    const other = await new UserRepository(db).create({ sub: 'other', name: 'Other', email: 'o@example.test' });
    await new DiscordRepository(db).linkDirect(other.id, 'customer-1', 'customer');
    await enable('thread-1').expect(200, { status: 'enabled' });
    await expect(listTickets()).resolves.toEqual({ items: [{ threadId: 'thread-1' }] });

    await disable('thread-1');

    await expect(
      db.selectFrom('userFeatureFlagOverride').select('userId').where('flag', '=', flag).execute(),
    ).resolves.toEqual([]);
  });

  it('lists no ticket for a grant an admin made', async () => {
    await setByAdmin(true);

    await enable('thread-1').expect(200, { status: 'already-enabled' });

    await expect(listTickets()).resolves.toEqual({ items: [] });
  });

  it('rejects a ticket owner without a linked account', async () => {
    await enable('thread-1', 'stranger').expect(404);

    expect(await getOverride()).toBeUndefined();
  });

  it('requires the internal secret', async () => {
    await request(app.getHttpServer())
      .put('/api/internal/discord/support-mode/thread-1')
      .send({ discordUserId: 'customer-1' })
      .expect(401);
    await request(app.getHttpServer()).delete('/api/internal/discord/support-mode/thread-1').expect(401);
    await request(app.getHttpServer()).get('/api/internal/discord/support-mode').expect(401);
  });
});
