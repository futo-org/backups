import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { FileMigrationProvider, Kysely, Migrator, sql } from 'kysely';
import { randomUUID } from 'node:crypto';
import { readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { DiscordInternalController } from 'src/controllers/discordInternal.controller.js';
import { env } from 'src/env.js';
import { ConnectionRepository } from 'src/repositories/connection.repository.js';
import { CryptoRepository } from 'src/repositories/crypto.repository.js';
import { DiscordRepository } from 'src/repositories/discord.repository.js';
import { UserRepository } from 'src/repositories/user.repository.js';
import { UserAllowlistRepository } from 'src/repositories/userAllowlist.repository.js';
import { DB } from 'src/schema/index.js';
import { AuthService } from 'src/services/auth.service.js';
import { DiscordService } from 'src/services/discord.service.js';
import { getKyselyConfig } from 'src/utils/database.js';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { newMocks } from './mocks.js';

class InviteFixtureRepository {
  constructor(private db: Kysely<DB>) {}

  async reset() {
    await this.db.deleteFrom('discordLinks').execute();
    await this.db.deleteFrom('userAllowlist').execute();
    await this.db.deleteFrom('discordInviteBatches').execute();
    await this.db.deleteFrom('users').execute();
  }

  getClaim(discordUserId: string) {
    return this.db
      .selectFrom('userAllowlist')
      .selectAll()
      .where('discordUserId', '=', discordUserId)
      .executeTakeFirst();
  }

  getRequests(allowlistId: string) {
    return this.db.selectFrom('discordLinkRequests').selectAll().where('allowlistId', '=', allowlistId).execute();
  }

  consumeLegacyToken(code: string) {
    return this.db.deleteFrom('discordLinkRequests').where('code', '=', code).returningAll().executeTakeFirst();
  }

  expireRequest(code: string) {
    return this.db
      .updateTable('discordLinkRequests')
      .set({ expiresAt: sql<Date>`clock_timestamp() - interval '1 second'` })
      .where('code', '=', code)
      .execute();
  }

  rejectLinks() {
    return sql`ALTER TABLE "discordLinks" ADD CONSTRAINT test_reject_links CHECK (false)`.execute(this.db);
  }

  allowLinks() {
    return sql`ALTER TABLE "discordLinks" DROP CONSTRAINT test_reject_links`.execute(this.db);
  }

  async discordIdAfterUser(userId: string) {
    for (let index = 0; index < 100; index++) {
      const discordUserId = `discord-${index}`;
      const { rows } = await sql<{
        ordered: boolean;
      }>`SELECT hashtext(${userId}) < hashtext(${discordUserId}) AS ordered`.execute(this.db);
      if (rows[0].ordered) {
        return discordUserId;
      }
    }
    throw new Error('No Discord identity with a later advisory lock key');
  }

  async holdNormalLink(requestId: string, userId: string, discordUserId: string) {
    let proceed!: () => void;
    let locked!: () => void;
    const start = new Promise<void>((resolve) => {
      proceed = resolve;
    });
    const ready = new Promise<void>((resolve) => {
      locked = resolve;
    });
    const result = this.db.transaction().execute(async (transaction) => {
      await sql`SELECT pg_advisory_xact_lock(hashtext(${userId}))`.execute(transaction);
      locked();
      await start;
      return new DiscordRepository(transaction).link(requestId, userId, discordUserId, 'customer');
    });
    await Promise.race([ready, result]);
    return { proceed, result };
  }

  cancelBatch(batchId: string, revokeUnused: boolean) {
    return this.db.transaction().execute(async (trx) => {
      await sql`SELECT pg_advisory_xact_lock(hashtext(${batchId}))`.execute(trx);
      await trx
        .updateTable('discordInviteBatches')
        .set({ cancelledAt: new Date() })
        .where('id', '=', batchId)
        .execute();
      if (revokeUnused) {
        await trx.deleteFrom('userAllowlist').where('batchId', '=', batchId).where('inviteUsed', '=', false).execute();
      }
    });
  }

  async holdBatch(batchId: string) {
    let release!: () => void;
    let locked!: () => void;
    const unlocked = new Promise<void>((resolve) => {
      release = resolve;
    });
    const ready = new Promise<void>((resolve) => {
      locked = resolve;
    });
    const finished = this.db.transaction().execute(async (trx) => {
      await sql`SELECT pg_advisory_xact_lock(hashtext(${batchId}))`.execute(trx);
      locked();
      await unlocked;
    });
    await Promise.race([ready, finished]);
    return { release, finished };
  }

  async waitForBlockedTransaction(applicationName: string) {
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline) {
      const { rows } = await sql<{ waiting: number }>`SELECT count(*)::int AS waiting FROM pg_locks l
        JOIN pg_stat_activity a ON a.pid = l.pid
        WHERE l.locktype = 'advisory' AND NOT l.granted AND a.application_name = ${applicationName}`.execute(this.db);
      if (rows[0].waiting > 0) {
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    throw new Error('Expected a transaction waiting on the batch lock');
  }
}

class TrackingUserRepository extends UserRepository {
  attempts = 0;

  constructor(
    db: Kysely<DB>,
    private afterInviteConsumed?: () => Promise<void>,
  ) {
    super(db);
  }

  override withRegistration(...[sub, operation]: Parameters<UserRepository['withRegistration']>) {
    return super.withRegistration(sub, (repositories) => {
      this.attempts++;
      const afterInviteConsumed = this.afterInviteConsumed;
      if (afterInviteConsumed) {
        const consumeInviteRequest = repositories.discord.consumeInviteRequest.bind(repositories.discord);
        repositories.discord.consumeInviteRequest = async (code) => {
          const request = await consumeInviteRequest(code);
          if (request) {
            await afterInviteConsumed();
          }
          return request;
        };
      }
      return operation(repositories);
    });
  }
}

describe('Discord invite reservations (integration)', () => {
  const schema = `discord_invites_${randomUUID().replaceAll('-', '')}`;
  const recyclingEnabled = env.DISCORD_INVITE_RECYCLING_ENABLED;
  let adminDb: Kysely<DB>;
  let db: Kysely<DB>;
  let discord: DiscordRepository;
  let allowlist: UserAllowlistRepository;
  let fixtures: InviteFixtureRepository;
  let app: INestApplication<App>;
  let auth: AuthService;
  const allowedEmailDomains = env.ALLOWED_EMAIL_DOMAINS;

  const createAuth = (users = new UserRepository(db)) => {
    const mocks = newMocks();
    return new AuthService(
      mocks.logger as never,
      mocks.oidc as never,
      users,
      mocks.crypto,
      mocks.session as never,
      mocks.wideContext,
      new ConnectionRepository(db),
      mocks.ticket as never,
      mocks.repository as never,
    );
  };

  const createBatch = (maxClaims = 1, messageId: string | null = 'posted-message') =>
    discord.createBatch({
      guildId: 'guild-1',
      channelId: 'channel-1',
      messageId,
      maxClaims,
      createdByDiscordUserId: 'staff-1',
    });
  const reserve = (discordUserId: string, batchId: string | null, expiresAt = new Date(Date.now() + 600_000)) =>
    discord.claimInvite(discordUserId, `user-${discordUserId}`, batchId, randomUUID().toUpperCase(), {
      code: randomUUID(),
      expiresAt,
    });
  const claim = async (discordUserId: string, batchId: string | null, expiresAt?: Date) => {
    const result = await reserve(discordUserId, batchId, expiresAt);
    if (result.status !== 'ok') {
      throw new Error(`Unexpected claim result: ${result.status}`);
    }
    return result;
  };

  beforeAll(async () => {
    adminDb = new Kysely(getKyselyConfig());
    await sql`CREATE SCHEMA ${sql.id(schema)}`.execute(adminDb);
    db = new Kysely({
      ...getKyselyConfig({ connection: { TimeZone: 'UTC', search_path: schema, application_name: schema }, max: 20 }),
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
    discord = new DiscordRepository(db);
    allowlist = new UserAllowlistRepository(db);
    fixtures = new InviteFixtureRepository(db);
    auth = createAuth();
    const module = await Test.createTestingModule({
      controllers: [DiscordInternalController],
      providers: [{ provide: DiscordService, useValue: new DiscordService(discord, new CryptoRepository()) }],
    }).compile();
    app = module.createNestApplication();
    app.setGlobalPrefix('/api');
    await app.init();
  }, 30_000);

  beforeEach(async () => {
    env.DISCORD_INVITE_RECYCLING_ENABLED = true;
    env.ALLOWED_EMAIL_DOMAINS = [];
    await fixtures.reset();
  });

  afterAll(async () => {
    env.DISCORD_INVITE_RECYCLING_ENABLED = recyclingEnabled;
    env.ALLOWED_EMAIL_DOMAINS = allowedEmailDomains;
    await app?.close();
    await db?.destroy();
    await sql`DROP SCHEMA ${sql.id(schema)} CASCADE`.execute(adminDb);
    await adminDb.destroy();
  });

  it.each(['discord token', 'raw code'])(
    'rolls back %s redemption when account insertion fails and permits retry',
    async (mode) => {
      const batch = await createBatch();
      const reservation = await claim('customer-1', batch.id);
      const entry = await fixtures.getClaim('customer-1');
      await new UserRepository(db).create({ sub: 'existing', name: 'Existing', email: 'taken@example.test' });
      const inviteCode = mode === 'raw code' ? entry!.inviteCode : undefined;
      const token = mode === 'discord token' ? reservation.request.code : undefined;
      const users = new TrackingUserRepository(db);
      const signup = createAuth(users);

      await expect(
        signup.getOrCreateUser(
          { sub: 'new-customer', name: 'Customer', email: 'taken@example.test' },
          inviteCode,
          token,
        ),
      ).rejects.toMatchObject({ code: '23505' });

      expect(users.attempts).toBe(1);
      expect(await new UserRepository(db).getBySub('new-customer')).toBeUndefined();
      expect(await fixtures.getClaim('customer-1')).toMatchObject({ inviteUsed: false, inviteUsedAt: null });
      expect(await discord.getRequestByCode(reservation.request.code)).toBeDefined();
      expect(await discord.getInviteBatch(batch.id)).toMatchObject({ remaining: 0 });
      const user = await signup.getOrCreateUser(
        { sub: 'new-customer', name: 'Customer', email: 'new@example.test' },
        inviteCode,
        token,
      );
      expect(await fixtures.getClaim('customer-1')).toMatchObject({ inviteUsed: true });
      expect(await discord.getRequestByCode(reservation.request.code)).toBeUndefined();
      expect(await new ConnectionRepository(db).getByUser(user.id)).toHaveLength(1);
      if (mode === 'discord token') {
        expect(await discord.getLinkByDiscordUserId('customer-1')).toMatchObject({ userId: user.id });
      }
    },
  );

  it('rolls back the user, default connection and invite when Discord linking fails', async () => {
    const batch = await createBatch();
    const reservation = await claim('customer-1', batch.id);
    await fixtures.rejectLinks();
    try {
      await expect(
        auth.getOrCreateUser(
          { sub: 'new-customer', name: 'Customer', email: 'new@example.test' },
          undefined,
          reservation.request.code,
        ),
      ).rejects.toMatchObject({ code: '23514' });
    } finally {
      await fixtures.allowLinks();
    }

    expect(await new UserRepository(db).getBySub('new-customer')).toBeUndefined();
    expect(await fixtures.getClaim('customer-1')).toMatchObject({ inviteUsed: false });
    expect(await discord.getRequestByCode(reservation.request.code)).toBeDefined();
    expect(await discord.getLinkByDiscordUserId('customer-1')).toBeUndefined();
    const user = await auth.getOrCreateUser(
      { sub: 'new-customer', name: 'Customer', email: 'new@example.test' },
      undefined,
      reservation.request.code,
    );
    expect(await discord.getLinkByDiscordUserId('customer-1')).toMatchObject({ userId: user.id });
    expect(await new ConnectionRepository(db).getByUser(user.id)).toHaveLength(1);
  });

  it('serializes concurrent callbacks for the same account and creates one default connection', async () => {
    const batch = await createBatch();
    const reservation = await claim('customer-1', batch.id);
    const identity = { sub: 'new-customer', name: 'Customer', email: 'new@example.test' };

    const users = await Promise.all([
      auth.getOrCreateUser(identity, undefined, reservation.request.code),
      auth.getOrCreateUser(identity, undefined, reservation.request.code),
    ]);

    expect(users[0].id).toBe(users[1].id);
    expect(await new ConnectionRepository(db).getByUser(users[0].id)).toHaveLength(1);
    expect(await discord.getLinkByDiscordUserId('customer-1')).toMatchObject({ userId: users[0].id });
  });

  it('retries the whole registration when ordinary linking creates an advisory-lock deadlock', async () => {
    const identity = { sub: 'existing-customer', name: 'Customer', email: 'existing@example.test' };
    const user = await new UserRepository(db).create({ ...identity, id: '11111111-1111-1111-1111-111111111111' });
    const discordUserId = await fixtures.discordIdAfterUser(user.id);
    const batch = await createBatch();
    const reservation = await claim(discordUserId, batch.id);
    const linkRequest = await discord.createRequest({
      code: randomUUID(),
      discordUserId,
      discordUsername: 'customer',
      expiresAt: new Date(Date.now() + 600_000),
    });
    const registrationDb = new Kysely<DB>({
      ...getKyselyConfig({
        connection: { TimeZone: 'UTC', search_path: schema, application_name: schema },
      }),
      log: [],
    });
    const users = new TrackingUserRepository(registrationDb);
    const signup = createAuth(users);
    const normalLink = await fixtures.holdNormalLink(linkRequest.id, user.id, discordUserId);
    const registration = signup.getOrCreateUser(identity, undefined, reservation.request.code);
    try {
      await fixtures.waitForBlockedTransaction(schema);
      await new Promise((resolve) => setTimeout(resolve, 250));
      normalLink.proceed();

      const [registered, linked] = await Promise.all([registration, normalLink.result]);

      expect(registered.id).toBe(user.id);
      expect(linked?.userId).toBe(user.id);
      expect(users.attempts).toBe(2);
      expect(await fixtures.getClaim(discordUserId)).toMatchObject({ inviteUsed: true });
      expect(await discord.getLinkByDiscordUserId(discordUserId)).toMatchObject({ userId: user.id });
      expect(await discord.getRequestByCode(reservation.request.code)).toBeUndefined();
    } finally {
      normalLink.proceed();
      await Promise.allSettled([registration, normalLink.result]);
      await registrationDb.destroy();
    }
  });

  it.each(['link', 'linkDirect'] as const)(
    'retries standalone %s when ordinary linking is the deadlock victim',
    async (mode) => {
      const identity = { sub: 'existing-customer', name: 'Customer', email: 'existing@example.test' };
      const user = await new UserRepository(db).create({ ...identity, id: '11111111-1111-1111-1111-111111111111' });
      const discordUserId = await fixtures.discordIdAfterUser(user.id);
      const batch = await createBatch();
      const reservation = await claim(discordUserId, batch.id);
      const linkRequest = await discord.createRequest({
        code: randomUUID(),
        discordUserId,
        discordUsername: 'customer',
        expiresAt: new Date(Date.now() + 600_000),
      });
      let proceed!: () => void;
      let consumed!: () => void;
      const ready = new Promise<void>((resolve) => {
        consumed = resolve;
      });
      const released = new Promise<void>((resolve) => {
        proceed = resolve;
      });
      const users = new TrackingUserRepository(db, async () => {
        consumed();
        await released;
      });
      const registration = createAuth(users).getOrCreateUser(identity, undefined, reservation.request.code);
      let ordinaryDeadlocks = 0;
      const applicationName = `${schema}_ordinary`;
      const ordinaryDb = new Kysely<DB>({
        ...getKyselyConfig({
          connection: { TimeZone: 'UTC', search_path: schema, application_name: applicationName },
        }),
        log(event) {
          if (
            event.level === 'error' &&
            event.error instanceof Error &&
            'code' in event.error &&
            event.error.code === '40P01'
          ) {
            ordinaryDeadlocks++;
          }
        },
      });
      let linked: ReturnType<DiscordRepository['link']> | undefined;
      try {
        await Promise.race([ready, registration]);
        const ordinaryDiscord = new DiscordRepository(ordinaryDb);
        linked =
          mode === 'link'
            ? ordinaryDiscord.link(linkRequest.id, user.id, discordUserId, 'customer')
            : ordinaryDiscord.linkDirect(user.id, discordUserId, 'customer');
        await fixtures.waitForBlockedTransaction(applicationName);
        await new Promise((resolve) => setTimeout(resolve, 250));
        proceed();

        const [registered, link] = await Promise.all([registration, linked]);

        expect(registered.id).toBe(user.id);
        expect(link?.userId).toBe(user.id);
        expect(ordinaryDeadlocks).toBe(1);
        expect(users.attempts).toBe(1);
        expect(await fixtures.getClaim(discordUserId)).toMatchObject({ inviteUsed: true });
        expect(await discord.getLinkByDiscordUserId(discordUserId)).toMatchObject({ userId: user.id });
        expect(await discord.getRequestByCode(reservation.request.code)).toBeUndefined();
        if (mode === 'link') {
          expect(await discord.getRequestByCode(linkRequest.code)).toBeUndefined();
        }
      } finally {
        proceed();
        await Promise.allSettled([registration, linked]);
        await ordinaryDb.destroy();
      }
    },
  );

  it('stops after three deadlocks and restores the invitation after every aborted attempt', async () => {
    const batch = await createBatch();
    const reservation = await claim('customer-1', batch.id);
    const error = Object.assign(new Error('deadlock detected'), { code: '40P01' });
    let attempts = 0;

    await expect(
      new UserRepository(db).withRegistration('new-customer', async ({ discord }) => {
        attempts++;
        expect(await discord.consumeInviteRequest(reservation.request.code)).toBeDefined();
        throw error;
      }),
    ).rejects.toBe(error);

    expect(attempts).toBe(3);
    expect(await fixtures.getClaim('customer-1')).toMatchObject({ inviteUsed: false });
    expect(await discord.getRequestByCode(reservation.request.code)).toBeDefined();
  });

  it('leaves retrying an inherited transaction to its owner', async () => {
    const error = Object.assign(new Error('deadlock detected'), { code: '40P01' });
    let attempts = 0;

    await expect(
      db.transaction().execute((transaction) =>
        new UserRepository(transaction).withRegistration('new-customer', () => {
          attempts++;
          return Promise.reject(error);
        }),
      ),
    ).rejects.toBe(error);

    expect(attempts).toBe(1);
  });

  it('preserves a tokenless legacy in-flight reservation until recycling is explicitly enabled', async () => {
    env.DISCORD_INVITE_RECYCLING_ENABLED = false;
    const batch = await createBatch();
    const reservation = await claim('customer-1', batch.id);
    await fixtures.consumeLegacyToken(reservation.request.code);

    const status = await discord.getInviteBatch(batch.id);
    const replacement = await reserve('customer-2', batch.id);

    expect(status).toMatchObject({ remaining: 0 });
    expect(replacement).toEqual({ status: 'exhausted' });
    expect(await fixtures.getClaim('customer-1')).toBeDefined();
    env.DISCORD_INVITE_RECYCLING_ENABLED = true;
    expect(await discord.getInviteBatch(batch.id)).toMatchObject({ remaining: 1 });
    expect(await fixtures.getClaim('customer-1')).toBeUndefined();
  });

  it('enables claim-time cleanup only after recycling is activated', async () => {
    env.DISCORD_INVITE_RECYCLING_ENABLED = false;
    const batch = await createBatch();
    const reservation = await claim('customer-1', batch.id);
    await fixtures.consumeLegacyToken(reservation.request.code);
    expect(await reserve('customer-2', batch.id)).toEqual({ status: 'exhausted' });

    env.DISCORD_INVITE_RECYCLING_ENABLED = true;
    const replacement = await claim('customer-2', batch.id);

    expect(replacement.remaining).toBe(0);
    expect(await fixtures.getClaim('customer-1')).toBeUndefined();
  });

  it('atomically reserves one slot and replaces the token on concurrent claims by the same user', async () => {
    const batch = await createBatch();

    const claims = await Promise.all([claim('customer-1', batch.id), claim('customer-1', batch.id)]);

    const entry = await fixtures.getClaim('customer-1');
    expect(entry).toBeDefined();
    expect(await fixtures.getRequests(entry!.id)).toHaveLength(1);
    expect(claims.map(({ remaining }) => remaining)).toEqual([0, 0]);
    expect(await discord.getInviteBatch(batch.id)).toMatchObject({ remaining: 0 });
    const consumed = await Promise.all(claims.map(({ request }) => discord.consumeInviteRequest(request.code)));
    expect(consumed.filter(Boolean)).toHaveLength(1);
  });

  it('never exceeds batch capacity under concurrent claims', async () => {
    const batch = await createBatch(3);

    const claims = await Promise.all(Array.from({ length: 8 }, (_, index) => reserve(`customer-${index}`, batch.id)));

    expect(claims.filter(({ status }) => status === 'ok')).toHaveLength(3);
    expect(claims.filter(({ status }) => status === 'exhausted')).toHaveLength(5);
    expect(await discord.getInviteBatch(batch.id)).toMatchObject({ remaining: 0 });
  });

  it('reclaims an expired reservation and revokes both its token and raw invite code', async () => {
    const batch = await createBatch();
    const expired = await claim('customer-1', batch.id, new Date(Date.now() - 1000));
    const entry = await fixtures.getClaim('customer-1');

    const replacement = await claim('customer-2', batch.id);

    expect(replacement.remaining).toBe(0);
    expect(await fixtures.getClaim('customer-1')).toBeUndefined();
    expect(await discord.consumeInviteRequest(expired.request.code)).toBeUndefined();
    expect(await allowlist.consumeInviteCode(entry!.inviteCode)).toBeUndefined();
  });

  it('makes an expired user compete for a slot again instead of renewing a released reservation', async () => {
    const batch = await createBatch();
    await claim('customer-1', batch.id, new Date(Date.now() - 1000));
    await claim('customer-2', batch.id);

    const result = await reserve('customer-1', batch.id);

    expect(result).toEqual({ status: 'exhausted' });
  });

  it('renews an active reservation without creating another claim or leaving a usable old token', async () => {
    const batch = await createBatch();
    const first = await claim('customer-1', batch.id);
    const entry = await fixtures.getClaim('customer-1');

    const renewed = await claim('customer-1', batch.id);

    expect(renewed.remaining).toBe(0);
    const renewedEntry = await fixtures.getClaim('customer-1');
    expect(renewedEntry?.id).toBe(entry!.id);
    expect(await discord.consumeInviteRequest(first.request.code)).toBeUndefined();
    expect(await discord.consumeInviteRequest(renewed.request.code)).toBeDefined();
  });

  it('retains the slot while redemption is in flight before the Discord link is written', async () => {
    const batch = await createBatch();
    const reservation = await claim('customer-1', batch.id);

    const consumed = await discord.consumeInviteRequest(reservation.request.code);

    expect(consumed).toBeDefined();
    expect(await fixtures.getClaim('customer-1')).toMatchObject({ inviteUsed: true });
    expect(await discord.getLinkByDiscordUserId('customer-1')).toBeUndefined();
    const [status, next] = await Promise.all([discord.getInviteBatch(batch.id), reserve('customer-2', batch.id)]);
    expect(status).toMatchObject({ remaining: 0 });
    expect(next).toEqual({ status: 'exhausted' });
  });

  it('rejects consuming an invite token through ordinary account linking', async () => {
    const batch = await createBatch();
    const reservation = await claim('customer-1', batch.id);
    const user = await new UserRepository(db).create({
      name: 'Existing customer',
      email: 'existing@example.test',
      sub: randomUUID(),
    });

    const link = await discord.link(reservation.request.id, user.id, 'customer-1', 'customer');

    expect(link).toBeNull();
    expect(await discord.consumeInviteRequest(reservation.request.code)).toBeDefined();
  });

  it('rechecks expiry after waiting for the batch lock and releases the expired reservation', async () => {
    const batch = await createBatch();
    const expiresAt = new Date(Date.now() + 600_000);
    const reservation = await claim('customer-1', batch.id, expiresAt);
    const blocker = await fixtures.holdBatch(batch.id);
    const consumed = discord.consumeInviteRequest(reservation.request.code);
    try {
      await fixtures.waitForBlockedTransaction(schema);
      await fixtures.expireRequest(reservation.request.code);
    } finally {
      blocker.release();
      await blocker.finished;
    }

    expect(await consumed).toBeUndefined();

    expect(await discord.getInviteBatch(batch.id)).toMatchObject({ remaining: 1 });
    expect(await claim('customer-2', batch.id)).toMatchObject({ remaining: 0 });
  });

  it('serializes raw-code redemption with token redemption and never returns a used slot', async () => {
    const batch = await createBatch();
    const reservation = await claim('customer-1', batch.id);
    const entry = await fixtures.getClaim('customer-1');

    const results = await Promise.all([
      discord.consumeInviteRequest(reservation.request.code),
      allowlist.consumeInviteCode(entry!.inviteCode),
    ]);

    expect(results.filter(Boolean)).toHaveLength(1);
    expect(await fixtures.getClaim('customer-1')).toMatchObject({ inviteUsed: true });
    expect(await discord.getInviteBatch(batch.id)).toMatchObject({ remaining: 0 });
  });

  it('rejects an expired raw batch invite before a cleanup poll has run', async () => {
    const batch = await createBatch();
    await claim('customer-1', batch.id, new Date(Date.now() - 1000));
    const entry = await fixtures.getClaim('customer-1');

    expect(await allowlist.consumeInviteCode(entry!.inviteCode)).toBeUndefined();

    expect(await discord.getInviteBatch(batch.id)).toMatchObject({ remaining: 1 });
  });

  it('keeps personal staff invites persistent when their temporary login token expires', async () => {
    const reservation = await claim('customer-1', null, new Date(Date.now() - 1000));
    const entry = await fixtures.getClaim('customer-1');
    const batch = await createBatch();
    await discord.getInviteBatch(batch.id);

    const renewed = await claim('customer-1', null);

    const renewedEntry = await fixtures.getClaim('customer-1');
    expect(renewedEntry?.id).toBe(entry!.id);
    expect(renewed.remaining).toBeNull();
    expect(await discord.consumeInviteRequest(reservation.request.code)).toBeUndefined();
    expect(await allowlist.consumeInviteCode(entry!.inviteCode)).toBeDefined();
  });

  it('preserves legacy linked claims even when their unused flag and expired request disagree', async () => {
    const batch = await createBatch();
    await claim('customer-1', batch.id, new Date(Date.now() - 1000));
    const user = await new UserRepository(db).create({
      name: 'Existing customer',
      email: 'existing@example.test',
      sub: randomUUID(),
    });
    await discord.linkDirect(user.id, 'customer-1', 'customer');

    const status = await discord.getInviteBatch(batch.id);

    expect(status).toMatchObject({ remaining: 0 });
    expect(await fixtures.getClaim('customer-1')).toBeDefined();
  });

  it('stops renewal on cancelled batches while preserving already-issued valid tokens', async () => {
    const batch = await createBatch();
    const reservation = await claim('customer-1', batch.id);
    await fixtures.cancelBatch(batch.id, false);

    expect(await reserve('customer-1', batch.id)).toEqual({ status: 'cancelled' });
    expect(await discord.consumeInviteRequest(reservation.request.code)).toBeDefined();

    expect(await discord.getInviteBatch(batch.id)).toMatchObject({ cancelledAt: expect.any(Date), remaining: 0 });
  });

  it('allows a fresh claim from another active batch after a cancelled reservation expires', async () => {
    const cancelled = await createBatch();
    await claim('customer-1', cancelled.id, new Date(Date.now() - 1000));
    await fixtures.cancelBatch(cancelled.id, false);
    const active = await createBatch();

    const reservation = await claim('customer-1', active.id);

    expect(reservation.remaining).toBe(0);
    expect(await fixtures.getClaim('customer-1')).toMatchObject({ batchId: active.id });
  });

  it('serializes revoke-unused cancellation with redemption', async () => {
    const batch = await createBatch();
    const reservation = await claim('customer-1', batch.id);

    const [consumed] = await Promise.all([
      discord.consumeInviteRequest(reservation.request.code),
      fixtures.cancelBatch(batch.id, true),
    ]);

    const entry = await fixtures.getClaim('customer-1');
    expect(consumed ? entry?.inviteUsed : entry).toBe(consumed ? true : undefined);
    expect(await discord.consumeInviteRequest(reservation.request.code)).toBeUndefined();
    expect(await reserve('customer-2', batch.id)).toEqual({ status: 'cancelled' });
  });

  it('rolls back the allowlist reservation when token creation fails', async () => {
    const batch = await createBatch(2);
    const reservation = await claim('customer-1', batch.id);

    await expect(
      discord.claimInvite('customer-2', 'customer', batch.id, randomUUID(), {
        code: reservation.request.code,
        expiresAt: new Date(Date.now() + 600_000),
      }),
    ).rejects.toMatchObject({ code: '23505' });

    expect(await fixtures.getClaim('customer-2')).toBeUndefined();
    expect(await discord.getInviteBatch(batch.id)).toMatchObject({ remaining: 1 });
  });

  it('lists posted exhausted and cancelled batches and refreshes expired counts through the guarded API', async () => {
    const expiredBatch = await createBatch();
    await claim('customer-1', expiredBatch.id, new Date(Date.now() - 1000));
    const exhaustedBatch = await createBatch();
    await claim('customer-2', exhaustedBatch.id);
    const cancelledBatch = await createBatch();
    await fixtures.cancelBatch(cancelledBatch.id, false);
    await createBatch(1, null);

    const response = await request(app.getHttpServer())
      .get('/api/internal/discord/invite-batches')
      .set('X-Internal-Secret', env.INTERNAL_SECRET)
      .expect(200);

    expect(response.body.items).toHaveLength(3);
    expect(response.body.items).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ id: expiredBatch.id, remaining: 1 }),
        expect.objectContaining({ id: exhaustedBatch.id, remaining: 0 }),
        expect.objectContaining({ id: cancelledBatch.id, cancelledAt: expect.any(String) }),
      ]),
    );
    expect(await fixtures.getClaim('customer-1')).toBeUndefined();
    await request(app.getHttpServer())
      .get(`/api/internal/discord/invite-batches/${expiredBatch.id}`)
      .set('X-Internal-Secret', env.INTERNAL_SECRET)
      .expect(200);
    await request(app.getHttpServer())
      .get(`/api/internal/discord/invite-batches/${randomUUID()}`)
      .set('X-Internal-Secret', env.INTERNAL_SECRET)
      .expect(404);
    await request(app.getHttpServer())
      .get('/api/internal/discord/invite-batches/invalid')
      .set('X-Internal-Secret', env.INTERNAL_SECRET)
      .expect(400);
    await request(app.getHttpServer()).get('/api/internal/discord/invite-batches').expect(401);
  });
});
