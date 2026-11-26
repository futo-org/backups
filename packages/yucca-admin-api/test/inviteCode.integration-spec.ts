import { EmailRepository } from '@common/server/email';
import { MetricService } from '@common/server/otel';
import { jest } from '@jest/globals';
import { INestApplication } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { OidcRepository } from 'src/repositories/oidc.repository.js';
import request from 'supertest';
import { App } from 'supertest/types';
import { controllers, imports, providers } from '../src/app.module.js';
import { newMetricServiceMock } from './mocks.js';
import { testUtils } from './testUtils.js';

const authCookie = ['yucca-admin-sub=admin', 'yucca-admin-access-token=token'];

describe('InviteCodeController (e2e)', () => {
  let app: INestApplication<App>;

  beforeAll(async () => {
    const moduleFixture: TestingModule = await Test.createTestingModule({
      imports,
      controllers,
      providers: [MetricService, ...providers],
    })
      .overrideProvider(MetricService)
      .useValue(newMetricServiceMock())
      .overrideProvider(OidcRepository)
      .useValue({ onModuleInit: jest.fn(), fetchUserInfo: jest.fn().mockResolvedValue({ sub: 'admin' }) })
      .overrideProvider(EmailRepository)
      .useValue({ send: jest.fn(), sendBatch: jest.fn() })
      .compile();

    app = moduleFixture.createNestApplication();
    app.setGlobalPrefix('/api');
    await app.init();
  });

  afterAll(async () => {
    await app.close();
  });

  beforeEach(async () => {
    await testUtils.resetDatabase();
  });

  const create = (body: object) =>
    request(app.getHttpServer()).post('/api/invite-codes').set('Cookie', authCookie).send(body);

  it('requires authentication', async () => {
    await request(app.getHttpServer()).get('/api/invite-codes').expect(401);
    await request(app.getHttpServer()).post('/api/invite-codes').send({ name: 'Meetup' }).expect(401);
  });

  describe('POST /invite-codes', () => {
    it('generates a code with a shareable link', async () => {
      const { body } = await create({ name: 'Immich meetup' }).expect(201);

      expect(body.inviteCode).toEqual(
        expect.objectContaining({
          name: 'Immich meetup',
          code: expect.stringMatching(/^[0-9A-HJKMNP-TV-Z]{10}$/),
          maxUses: null,
          uses: 0,
          expiresAt: null,
          revokedAt: null,
        }),
      );
      expect(body.inviteCode.inviteUrl).toBe(`http://localhost:5173/login/invite?code=${body.inviteCode.code}`);
    });

    it('accepts a custom code, use limit and expiry', async () => {
      const expiresAt = '2030-01-01T00:00:00.000Z';

      const { body } = await create({ name: 'Podcast', code: 'futo-pod', maxUses: 50, expiresAt }).expect(201);

      expect(body.inviteCode).toEqual(expect.objectContaining({ code: 'FUTO-POD', maxUses: 50, expiresAt }));
    });

    it('rejects a duplicate name or code', async () => {
      await create({ name: 'Podcast', code: 'FUTO-POD' }).expect(201);

      await create({ name: 'Podcast', code: 'OTHER-CODE' }).expect(409);
      await create({ name: 'Another', code: 'futo-pod' }).expect(409);
    });

    it('rejects a code that collides with a single-use invite code', async () => {
      await testUtils.createAllowlistEntry({ email: 'alice@example.com', inviteCode: 'ALICE12345' });

      await create({ name: 'Collision', code: 'ALICE12345' }).expect(409);
    });

    it('validates the request', async () => {
      await create({}).expect(400);
      await create({ name: 'Bad code', code: 'no spaces!' }).expect(400);
      await create({ name: 'Zero uses', maxUses: 0 }).expect(400);
      await create({ name: 'Too many uses', maxUses: 2_147_483_648 }).expect(400);
    });
  });

  describe('GET /invite-codes', () => {
    it('lists codes with their use counts', async () => {
      const { body: created } = await create({ name: 'Meetup', maxUses: 10 }).expect(201);
      const alice = await testUtils.createUser({ email: 'alice@example.com' });
      const bob = await testUtils.createUser({ email: 'bob@example.com' });
      await testUtils.createInviteCodeRedemption(created.inviteCode.id, alice.id);
      await testUtils.createInviteCodeRedemption(created.inviteCode.id, bob.id);
      await create({ name: 'Unused' }).expect(201);

      const { body } = await request(app.getHttpServer())
        .get('/api/invite-codes')
        .set('Cookie', authCookie)
        .expect(200);

      expect(body.items).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ name: 'Meetup', uses: 2, maxUses: 10 }),
          expect.objectContaining({ name: 'Unused', uses: 0 }),
        ]),
      );
    });
  });

  describe('GET /invite-codes/:id', () => {
    it('returns who redeemed the code', async () => {
      const { body: created } = await create({ name: 'Meetup' }).expect(201);
      const alice = await testUtils.createUser({ email: 'alice@example.com' });
      await testUtils.createInviteCodeRedemption(created.inviteCode.id, alice.id);

      const { body } = await request(app.getHttpServer())
        .get(`/api/invite-codes/${created.inviteCode.id}`)
        .set('Cookie', authCookie)
        .expect(200);

      expect(body.inviteCode).toEqual(expect.objectContaining({ name: 'Meetup', uses: 1 }));
      expect(body.redemptions).toEqual([
        { userId: alice.id, email: 'alice@example.com', createdAt: expect.any(String) },
      ]);
    });

    it('keeps counting the use of a deleted account', async () => {
      const { body: created } = await create({ name: 'Meetup', maxUses: 1 }).expect(201);
      const alice = await testUtils.createUser({ email: 'alice@example.com' });
      await testUtils.createInviteCodeRedemption(created.inviteCode.id, alice.id);

      await request(app.getHttpServer()).delete(`/api/user/${alice.id}`).set('Cookie', authCookie).expect(204);

      const { body } = await request(app.getHttpServer())
        .get(`/api/invite-codes/${created.inviteCode.id}`)
        .set('Cookie', authCookie)
        .expect(200);
      expect(body.inviteCode).toEqual(expect.objectContaining({ uses: 1, maxUses: 1 }));
      expect(body.redemptions).toEqual([{ userId: null, email: null, createdAt: expect.any(String) }]);
    });

    it('returns 404 for an unknown code', async () => {
      await request(app.getHttpServer())
        .get('/api/invite-codes/00000000-0000-4000-8000-000000000000')
        .set('Cookie', authCookie)
        .expect(404);
    });
  });

  describe('DELETE /invite-codes/:id', () => {
    it('revokes the code and keeps its history', async () => {
      const { body: created } = await create({ name: 'Meetup' }).expect(201);
      const alice = await testUtils.createUser({ email: 'alice@example.com' });
      await testUtils.createInviteCodeRedemption(created.inviteCode.id, alice.id);

      const { body: revoked } = await request(app.getHttpServer())
        .delete(`/api/invite-codes/${created.inviteCode.id}`)
        .set('Cookie', authCookie)
        .expect(200);

      expect(revoked.inviteCode).toEqual(
        expect.objectContaining({ name: 'Meetup', uses: 1, revokedAt: expect.any(String) }),
      );
      const { body } = await request(app.getHttpServer())
        .get(`/api/invite-codes/${created.inviteCode.id}`)
        .set('Cookie', authCookie)
        .expect(200);
      expect(body.redemptions).toEqual([
        { userId: alice.id, email: 'alice@example.com', createdAt: expect.any(String) },
      ]);
    });

    it('keeps the first revocation time when revoked twice', async () => {
      const { body: created } = await create({ name: 'Meetup' }).expect(201);
      const revoke = () =>
        request(app.getHttpServer())
          .delete(`/api/invite-codes/${created.inviteCode.id}`)
          .set('Cookie', authCookie)
          .expect(200);

      const { body: first } = await revoke();
      const { body: second } = await revoke();

      expect(second.inviteCode.revokedAt).toBe(first.inviteCode.revokedAt);
    });

    it('returns 404 for an unknown code', async () => {
      await request(app.getHttpServer())
        .delete('/api/invite-codes/00000000-0000-4000-8000-000000000000')
        .set('Cookie', authCookie)
        .expect(404);
    });
  });
});
