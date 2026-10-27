import { MetricService } from '@common/server/otel';
import { INestApplication } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { Kysely } from 'kysely';
import { randomUUID } from 'node:crypto';
import { env } from 'src/env.js';
import { DB } from 'src/schema/index.js';
import { getKyselyConfig } from 'src/utils/database.js';
import request from 'supertest';
import { App } from 'supertest/types';
import { controllers, imports, providers } from '../src/app.module.js';
import { newMetricServiceMock } from './mocks.js';
import { testUtils } from './testUtils.js';

describe('Support log sessions (e2e)', () => {
  let app: INestApplication<App>;
  let db: Kysely<DB>;
  let cookie: string;
  let userId: string;
  let sessionId: string;

  const report = (reportId: string, lines: number, finished = false) =>
    request(app.getHttpServer())
      .post(`/api/internal/support-logs/sessions/${sessionId}/stats`)
      .set('X-Internal-Secret', env.INTERNAL_SECRET)
      .send({ reportId, lines, bytes: lines * 10, batches: 1, droppedLines: 0, finished });

  const refreshToken = () =>
    request(app.getHttpServer()).post(`/api/support-logs/sessions/${sessionId}/token`).set('Cookie', cookie);

  const counts = () =>
    db
      .selectFrom('supportLogSessions')
      .select(['lineCount', 'byteCount', 'batchCount', 'finishedAt'])
      .where('id', '=', sessionId)
      .executeTakeFirstOrThrow();

  beforeAll(async () => {
    const moduleFixture: TestingModule = await Test.createTestingModule({
      imports,
      controllers,
      providers: [MetricService, ...providers],
    })
      .overrideProvider(MetricService)
      .useValue(newMetricServiceMock())
      .compile();

    app = moduleFixture.createNestApplication();
    app.setGlobalPrefix('/api');
    await app.init();
    db = new Kysely(getKyselyConfig());
  });

  afterAll(async () => {
    await db.destroy();
    await app.close();
  });

  beforeEach(async () => {
    await testUtils.resetDatabase();
    const { user, session } = await testUtils.createUser();
    cookie = `yucca-access-token=${session.accessToken}`;
    userId = user.id;
    await db
      .insertInto('userFeatureFlagOverride')
      .values({ userId: user.id, flag: 'support-log-streaming', value: true, setBy: 'test' })
      .execute();

    const { body } = await request(app.getHttpServer())
      .post('/api/support-logs/sessions')
      .set('Cookie', cookie)
      .send({ jobId: 'job-1', jobName: 'repository-backup', includesPaths: false })
      .expect(201);
    sessionId = body.id;
  });

  it('counts a report once even when the streamer resends it', async () => {
    const reportId = randomUUID();

    await report(reportId, 5).expect(204);
    await report(reportId, 5).expect(204);
    await report(randomUUID(), 2, true).expect(204);

    const { finishedAt, ...counters } = await counts();
    expect(counters).toMatchObject({ lineCount: '7', byteCount: '70', batchCount: '2' });
    expect(finishedAt).not.toBeNull();
  });

  it('reports an unknown session so the streamer drops its stats', async () => {
    sessionId = randomUUID();

    await report(randomUUID(), 1).expect(404);
  });

  it('rejects a report without an id', async () => {
    await request(app.getHttpServer())
      .post(`/api/internal/support-logs/sessions/${sessionId}/stats`)
      .set('X-Internal-Secret', env.INTERNAL_SECRET)
      .send({ lines: 1, bytes: 1, batches: 1, droppedLines: 0 })
      .expect(400);
  });

  it('refuses to open a session for an account without the feature', async () => {
    const { session } = await testUtils.createUser('bar', 'bar@example.com', 'bar');

    await request(app.getHttpServer())
      .post('/api/support-logs/sessions')
      .set('Cookie', `yucca-access-token=${session.accessToken}`)
      .send({ jobId: 'job-2', jobName: 'repository-backup', includesPaths: false })
      .expect(403);
  });

  it('stops refreshing a session token once the feature is revoked', async () => {
    await refreshToken().expect(201);
    await testUtils.setFeatureOverride(userId, 'support-log-streaming', false);
    await refreshToken().expect(403);
  });
});
