import { NotFoundException, ServiceUnavailableException } from '@nestjs/common';
import { AuthDto } from 'src/dto/auth.dto.js';
import { env } from 'src/env.js';
import { SupportLogService } from 'src/services/supportLog.service.js';
import { Mocks, newMocks } from '../../test/mocks.js';

const auth = {
  id: 'b6b7c231-6dc0-4bdc-82c1-92677b1e6c1c',
  connectionId: '0d6c4d5e-8f39-4a4b-a7a8-6a0f3c1f2b10',
  features: { 'support-log-streaming': true },
} as unknown as AuthDto;

const session = {
  id: '5b0f3a5e-2a7c-4f1e-9a43-1f6f4c7b2e01',
  userId: auth.id,
  connectionId: auth.connectionId,
  jobId: 'job-1',
  jobName: 'RepositoryBackup',
  includesPaths: false,
  clientVersion: '1.9.0',
  lineCount: 0,
  byteCount: 0,
  batchCount: 0,
  droppedLineCount: 0,
  createdAt: new Date('2026-10-27T00:00:00Z'),
  lastBatchAt: null,
  finishedAt: null,
};

const reportId = '9f1c2d3e-4b5a-4c6d-8e7f-0a1b2c3d4e5f';

describe(SupportLogService.name, () => {
  let sut: SupportLogService;
  let mocks: Mocks;

  beforeEach(() => {
    env.SUPPORT_LOGS_URL = 'https://support-logs.example/';
    mocks = newMocks();
    sut = new SupportLogService(mocks.supportLogSession as never, mocks.jwt as never, mocks.wideContext as never);
    mocks.jwt.signAsync.mockResolvedValue('signed-token' as never);
  });

  describe('createSession', () => {
    it('records the session against the caller and its connection', async () => {
      mocks.supportLogSession.create.mockResolvedValue(session);

      const result = await sut.createSession(auth, {
        jobId: 'job-1',
        jobName: 'RepositoryBackup',
        includesPaths: false,
        clientVersion: '1.9.0',
      });

      expect(mocks.supportLogSession.create).toHaveBeenCalledWith({
        userId: auth.id,
        connectionId: auth.connectionId,
        jobId: 'job-1',
        jobName: 'RepositoryBackup',
        includesPaths: false,
        clientVersion: '1.9.0',
      });
      expect(result).toEqual({
        id: session.id,
        token: 'signed-token',
        url: 'https://support-logs.example/v1/batches',
        expiresAt: expect.any(Date),
      });
    });

    it('refuses to open sessions when no streamer is configured', async () => {
      env.SUPPORT_LOGS_URL = '';

      await expect(
        sut.createSession(auth, { jobId: 'job-1', jobName: 'RepositoryBackup', includesPaths: false }),
      ).rejects.toBeInstanceOf(ServiceUnavailableException);
      expect(mocks.supportLogSession.create).not.toHaveBeenCalled();
    });

    it('signs a token scoped to the streamer audience and the session', async () => {
      mocks.supportLogSession.create.mockResolvedValue(session);

      await sut.createSession(auth, { jobId: 'job-1', jobName: 'RepositoryBackup', includesPaths: false });

      expect(mocks.jwt.signAsync).toHaveBeenCalledWith(
        { sid: session.id, job: 'job-1', jobName: 'RepositoryBackup', connection: auth.connectionId },
        { subject: auth.id, audience: 'support-logs', expiresIn: 6 * 60 * 60 },
      );
    });

    it('omits the connection claim for sessions without a connection', async () => {
      mocks.supportLogSession.create.mockResolvedValue({ ...session, connectionId: null });

      await sut.createSession({ ...auth, connectionId: null }, { jobId: 'job-1', jobName: 'x', includesPaths: true });

      expect(mocks.jwt.signAsync).toHaveBeenCalledWith(
        { sid: session.id, job: 'job-1', jobName: 'RepositoryBackup' },
        expect.anything(),
      );
    });
  });

  describe('refreshToken', () => {
    it('issues a fresh token for an open session of the caller', async () => {
      mocks.supportLogSession.getById.mockResolvedValue(session);

      await expect(sut.refreshToken(auth, session.id)).resolves.toMatchObject({ token: 'signed-token' });
    });

    it.each([
      ['missing', undefined],
      ['owned by someone else', { ...session, userId: 'someone-else' }],
      ['finished', { ...session, finishedAt: new Date() }],
    ])('refuses a session that is %s', async (_, found) => {
      mocks.supportLogSession.getById.mockResolvedValue(found);

      await expect(sut.refreshToken(auth, session.id)).rejects.toBeInstanceOf(NotFoundException);
      expect(mocks.jwt.signAsync).not.toHaveBeenCalled();
    });
  });

  describe('recordStats', () => {
    it('adds the reported increments', async () => {
      mocks.supportLogSession.addStats.mockResolvedValue('applied');

      await sut.recordStats(session.id, {
        reportId,
        lines: 10,
        bytes: 100,
        batches: 1,
        droppedLines: 2,
        lastBatchAt: '2026-10-27T01:00:00.000Z',
        finished: true,
      });

      expect(mocks.supportLogSession.addStats).toHaveBeenCalledWith(session.id, reportId, {
        lines: 10,
        bytes: 100,
        batches: 1,
        droppedLines: 2,
        lastBatchAt: new Date('2026-10-27T01:00:00.000Z'),
        finished: true,
      });
    });

    it('reports unknown sessions so the streamer stops retrying them', async () => {
      mocks.supportLogSession.addStats.mockResolvedValue('missing');

      await expect(
        sut.recordStats(session.id, { reportId, lines: 1, bytes: 1, batches: 1, droppedLines: 0, finished: false }),
      ).rejects.toBeInstanceOf(NotFoundException);
    });

    it('accepts a report it has already applied without counting it again', async () => {
      mocks.supportLogSession.addStats.mockResolvedValue('duplicate');

      await expect(
        sut.recordStats(session.id, { reportId, lines: 1, bytes: 1, batches: 1, droppedLines: 0, finished: false }),
      ).resolves.toBeUndefined();
      expect(mocks.supportLogSession.addStats).toHaveBeenCalledTimes(1);
    });
  });
});
