import { submitMetricBackupEnd, submitStructuredLog } from '@futo-org/backups-api-client';
import { jest } from '@jest/globals';
import { randomUUID } from 'node:crypto';
import { REPOSITORY_DEFAULT_CLOUD_UUID } from '../src/const.js';
import { BackendType, BootstrapStatus, JobName, JobStatus } from '../src/enum.js';
import { BackendRepository } from '../src/repositories/backend.repository.js';
import { BootstrapRepository } from '../src/repositories/bootstrap.repository.js';
import { ConfigRepository } from '../src/repositories/config.repository.js';
import { JobRepository } from '../src/repositories/job.repository.js';
import { RepositoryRepository } from '../src/repositories/repository.repository.js';
import { BootstrapService } from '../src/services/bootstrap.service.js';
import { createTestingModule, TestContext, waitFor } from './testUtils.js';

const apiSubmitMetricBackupEnd = submitMetricBackupEnd as jest.Mock;
const apiSubmitStructuredLog = submitStructuredLog as jest.Mock;

let ctx: TestContext;

beforeAll(async () => {
  ctx = await createTestingModule();
}, 15_000);

afterAll(async () => {
  await ctx.app.close();
});

beforeEach(async () => {
  jest.clearAllMocks();
  await ctx.db.deleteFrom('futo_backups_jobs').execute();
  await ctx.db.deleteFrom('futo_backups_repositories').execute();

  await ctx.module.get(BackendRepository).updateBackend(REPOSITORY_DEFAULT_CLOUD_UUID, {
    type: BackendType.Yucca,
    url: 'http://yucca.test',
    accessToken: 'test-token',
  });
  await ctx.module.get(ConfigRepository).enableTelemetry();
});

describe('Bootstrap', () => {
  it('marks interrupted jobs as incomplete and reports only the backup to the backend', async () => {
    const repositoryId = randomUUID();
    const remoteId = `remote-${repositoryId}`;
    const now = new Date();

    await ctx.module.get(RepositoryRepository).create({
      id: repositoryId,
      remoteId,
      backendId: REPOSITORY_DEFAULT_CLOUD_UUID,
      retentionPolicy: null,
      siteCode: null,
      storageClusterCode: null,
    });

    await ctx.db
      .insertInto('futo_backups_jobs')
      .values(
        [
          { name: JobName.RepositoryBackup, data: { repositoryId } },
          { name: JobName.RepositoryRestore, data: { repositoryId, snapshotId: 'snapshot-1', options: {} } },
        ].map((job) => ({
          ...job,
          repositoryId,
          status: JobStatus.Running,
          logFilePath: 'logs/jobs/interrupted.jsonl',
          queuedAt: now,
          start: now,
        })),
      )
      .execute();

    await ctx.module.get(BootstrapService).onApplicationBootstrap();

    expect(ctx.module.get(BootstrapRepository).getStatus()).toBe(BootstrapStatus.Ready);

    const jobs = await ctx.module.get(JobRepository).getAll(repositoryId);
    expect(jobs.map(({ name, status }) => ({ name, status }))).toEqual(
      expect.arrayContaining([
        { name: JobName.RepositoryBackup, status: JobStatus.Incomplete },
        { name: JobName.RepositoryRestore, status: JobStatus.Incomplete },
      ]),
    );

    await waitFor(() => apiSubmitStructuredLog.mock.calls.some(([{ summary }]) => summary === 'Backup finished'));
    expect(apiSubmitStructuredLog).toHaveBeenCalledWith(
      {
        summary: 'Backup finished',
        data: expect.objectContaining({ repositoryId, lastBackupStatus: JobStatus.Incomplete }),
      },
      expect.any(Object),
    );

    await waitFor(() => apiSubmitMetricBackupEnd.mock.calls.length > 0);
    expect(apiSubmitMetricBackupEnd).toHaveBeenCalledTimes(1);
    expect(apiSubmitMetricBackupEnd).toHaveBeenCalledWith(
      remoteId,
      { status: 'incomplete', durationMs: expect.any(Number) },
      expect.any(Object),
    );
  });
});
