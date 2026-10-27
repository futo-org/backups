import { jest } from '@jest/globals';
import { ForbiddenException } from '@nestjs/common';
import { PassThrough } from 'node:stream';
import { YuccaBackend } from '../backends/yucca.backend.js';
import { BackendType, JobName } from '../enum.js';
import { LoggingRepository } from '../repositories/logging.repository.js';
import { supportLogFilePath, SupportModeService } from './supportMode.service.js';

const backup = { id: 'job-1', name: JobName.RepositoryBackup };

const makeService = (settings?: { remainingRuns: number; streamToFuto: boolean; includePaths: boolean }) => {
  const backend = new YuccaBackend({ type: BackendType.Yucca, accessToken: 'token' });
  const config = {
    getSupportMode: jest.fn(() =>
      Promise.resolve(settings ?? { remainingRuns: 0, streamToFuto: false, includePaths: false }),
    ),
    setSupportMode: jest.fn(() => Promise.resolve()),
    consumeSupportModeRun: jest.fn(() => Promise.resolve(settings)),
  };
  const backends = { getBackend: jest.fn(() => Promise.resolve({ backend })) };
  const storage = {
    mkdir: jest.fn(() => Promise.resolve()),
    createWriteStream: jest.fn(() => new PassThrough()),
  };

  const service = new SupportModeService(
    config as never,
    backends as never,
    storage as never,
    LoggingRepository.create(),
  );

  return { service, backend, config, storage };
};

describe(SupportModeService.name, () => {
  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('places the support log next to the job log', () => {
    expect(supportLogFilePath('/state/logs/jobs/job-1.jsonl')).toBe('/state/logs/jobs/job-1.support.jsonl');
  });

  it('never spends a run on metrics syncs', async () => {
    const { service, config } = makeService({ remainingRuns: 3, streamToFuto: false, includePaths: false });

    await expect(
      service.begin({ id: 'job-1', name: JobName.RepositorySyncMetrics }, '/state/logs/jobs/job-1.jsonl'),
    ).resolves.toBeUndefined();
    expect(config.consumeSupportModeRun).not.toHaveBeenCalled();
  });

  it('runs without support mode once the runs are used up', async () => {
    const { service, storage } = makeService();

    await expect(service.begin(backup, '/state/logs/jobs/job-1.jsonl')).resolves.toBeUndefined();
    expect(storage.createWriteStream).not.toHaveBeenCalled();
  });

  it('keeps the logs local when streaming is off', async () => {
    const { service, backend, storage } = makeService({ remainingRuns: 1, streamToFuto: false, includePaths: false });
    const create = jest.spyOn(backend, 'createSupportLogSession');

    const session = await service.begin(backup, '/state/logs/jobs/job-1.jsonl');

    expect(session?.sessionId).toBeUndefined();
    expect(storage.createWriteStream).toHaveBeenCalledWith('/state/logs/jobs/job-1.support.jsonl');
    expect(create).not.toHaveBeenCalled();
  });

  it('opens a streaming session for the job when streaming is on', async () => {
    const { service, backend } = makeService({ remainingRuns: 1, streamToFuto: true, includePaths: false });
    const create = jest.spyOn(backend, 'createSupportLogSession').mockResolvedValue({
      id: 'session-1',
      token: 'jwt',
      url: 'https://support-logs.example/v1/batches',
      expiresAt: new Date(Date.now() + 3_600_000).toISOString(),
    });

    const session = await service.begin(backup, '/state/logs/jobs/job-1.jsonl');

    expect(session?.sessionId).toBe('session-1');
    expect(create).toHaveBeenCalledWith(
      expect.objectContaining({ jobId: 'job-1', jobName: JobName.RepositoryBackup, includesPaths: false }),
    );
  });

  it('still runs verbose and local when the streaming session cannot be opened', async () => {
    const { service, backend } = makeService({ remainingRuns: 1, streamToFuto: true, includePaths: true });
    jest.spyOn(backend, 'createSupportLogSession').mockRejectedValue(new Error('403'));

    const session = await service.begin(backup, '/state/logs/jobs/job-1.jsonl');

    expect(session).toBeDefined();
    expect(session?.sessionId).toBeUndefined();
  });

  it('reports streaming as available only with the feature', async () => {
    const { service, backend } = makeService();
    const features = jest.spyOn(backend, 'getFeatures').mockResolvedValue({ 'support-log-streaming': true });

    await expect(service.get()).resolves.toMatchObject({ streamingAvailable: true });

    features.mockResolvedValue({ 'support-log-streaming': false });
    await expect(service.get()).resolves.toMatchObject({ streamingAvailable: false });

    features.mockRejectedValue(new Error('offline'));
    await expect(service.get()).resolves.toMatchObject({ streamingAvailable: false });
  });

  it('refuses to turn streaming on for an account without the feature', async () => {
    const { service, backend, config } = makeService();
    jest.spyOn(backend, 'getFeatures').mockResolvedValue({});

    await expect(service.update({ remainingRuns: 1, streamToFuto: true, includePaths: false })).rejects.toBeInstanceOf(
      ForbiddenException,
    );
    await expect(service.update({ remainingRuns: 1, streamToFuto: false, includePaths: false })).resolves.toEqual({
      remainingRuns: 1,
      streamToFuto: false,
      includePaths: false,
      streamingAvailable: false,
    });
    expect(config.setSupportMode).toHaveBeenCalledTimes(1);
  });
});
