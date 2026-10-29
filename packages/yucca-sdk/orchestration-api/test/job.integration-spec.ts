import { jest } from '@jest/globals';
import { randomUUID } from 'node:crypto';
import { access, mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { JobName, JobStatus } from '../src/enum.js';
import { type GatewayEvent } from '../src/events/events.gateway.js';
import { ConfigRepository } from '../src/repositories/config.repository.js';
import { JobRepository } from '../src/repositories/job.repository.js';
import { ModuleConfigRepository } from '../src/repositories/moduleConfig.repository.js';
import { RepositoryService } from '../src/services/repository.service.js';
import { SupportSession } from '../src/utils/supportSession.js';
import { createTestingModule, TestContext } from './testUtils.js';

let ctx: TestContext;
let repositoryId: string;

const forget = (snapshotId: string) =>
  ({ name: JobName.RepositorySnapshotForget, data: { repositoryId, snapshotId } }) as const;

const getJob = (id: string) =>
  ctx.db.selectFrom('futo_backups_jobs').selectAll().where('id', '=', id).executeTakeFirstOrThrow();

const insertJob = async (status: JobStatus, queuedAt: Date, logFilePath = `logs/jobs/${randomUUID()}.jsonl`) => {
  const { id } = await ctx.db
    .insertInto('futo_backups_jobs')
    .values({
      name: JobName.RepositorySnapshotForget,
      repositoryId,
      data: { repositoryId, snapshotId: 'snapshot-1' },
      status,
      logFilePath,
      queuedAt,
    })
    .returning('id')
    .executeTakeFirstOrThrow();

  return id;
};

const backupOutcome = (snapshotId?: string) =>
  JSON.stringify({ errors: [], summary: snapshotId ? { type: 'backup', snapshotId } : undefined });

const blockForgetUntilAborted = () => {
  const started = Promise.withResolvers<void>();
  ctx.resticMock.forget.mockImplementationOnce(
    (...args: unknown[]) =>
      new Promise((_, reject) => {
        started.resolve();
        const signal = args[5] as AbortSignal;
        signal.addEventListener('abort', () => reject(signal.reason), { once: true });
      }) as never,
  );

  return started.promise;
};

beforeAll(async () => {
  ctx = await createTestingModule();

  const { repository } = await ctx.module
    .get(RepositoryService)
    .createRepository({ name: 'Jobs', worm: false, paths: ['/tmp/jobs'] }, ctx.backendId);
  repositoryId = repository.id;
}, 15_000);

afterAll(async () => {
  await ctx.app.close();
});

describe(JobRepository.name, () => {
  beforeEach(() => {
    ctx.resticMock.forget.mockReset();
  });

  it('runs a queued job and resolves its waiters once complete', async () => {
    const jobs = ctx.module.get(JobRepository);

    const id = await jobs.queue(forget('snapshot-1'));
    const job = await jobs.wait(id);

    expect(job.status).toBe(JobStatus.Complete);
    expect(ctx.resticMock.forget).toHaveBeenCalledWith(
      expect.anything(),
      expect.anything(),
      expect.anything(),
      'snapshot-1',
      true,
      expect.any(AbortSignal),
    );
  });

  it('resolves a wait on a job that already finished', async () => {
    const jobs = ctx.module.get(JobRepository);

    const id = await jobs.queue(forget('snapshot-1'));
    await jobs.wait(id);

    await expect(jobs.wait(id)).resolves.toMatchObject({ id, status: JobStatus.Complete });
  });

  it('records a failed job and rejects its waiters with the error', async () => {
    const jobs = ctx.module.get(JobRepository);
    ctx.resticMock.forget.mockRejectedValueOnce(new Error('restic forget failed'));

    const id = await jobs.queue(forget('snapshot-1'));

    await expect(jobs.wait(id)).rejects.toThrow('restic forget failed');
    const job = await getJob(id);
    expect(job.status).toBe(JobStatus.Failed);
    expect(job.outcome).toEqual({ errors: ['Error: restic forget failed'] });

    const log = await readFile(join(ctx.statePath, 'logs', 'jobs', `${id}.jsonl`), 'utf8');
    expect(log).toContain('restic forget failed');
  });

  it('resolves a stored log path against the current state directory', async () => {
    const jobs = ctx.module.get(JobRepository);
    const moduleConfig = ctx.module.get(ModuleConfigRepository);
    const originalStatePath = ctx.statePath;
    const movedStatePath = await mkdtemp(join(tmpdir(), 'yucca-moved-'));
    const customPathId = await insertJob(
      JobStatus.Complete,
      new Date('2026-10-13T00:00:00.000Z'),
      'logs/custom/elsewhere.jsonl',
    );

    try {
      await expect(jobs.getLogFilePath(customPathId)).resolves.toBe(
        join(originalStatePath, 'logs', 'custom', 'elsewhere.jsonl'),
      );

      moduleConfig.update({ statePath: movedStatePath });

      await expect(jobs.getLogFilePath(customPathId)).resolves.toBe(
        join(movedStatePath, 'logs', 'custom', 'elsewhere.jsonl'),
      );
      const stored = await getJob(customPathId);
      expect(stored.logFilePath).toBe('logs/custom/elsewhere.jsonl');
    } finally {
      moduleConfig.update({ statePath: originalStatePath });
    }
  });

  it('runs one job at a time in queue order', async () => {
    const jobs = ctx.module.get(JobRepository);
    const first = Promise.withResolvers<void>();
    ctx.resticMock.forget.mockImplementationOnce(() => first.promise as never);

    const firstId = await jobs.queue(forget('snapshot-1'));
    const secondId = await jobs.queue(forget('snapshot-2'));

    await expect(getJob(firstId)).resolves.toMatchObject({ status: JobStatus.Running });
    await expect(getJob(secondId)).resolves.toMatchObject({ status: JobStatus.Queued });

    first.resolve();
    await jobs.wait(secondId);

    expect(ctx.resticMock.forget.mock.calls.map((call) => call[3])).toEqual(['snapshot-1', 'snapshot-2']);
  });

  it('leaves jobs queued on a worker without the lock', async () => {
    const jobs = ctx.module.get(JobRepository);
    const moduleConfig = ctx.module.get(ModuleConfigRepository);
    moduleConfig.update({ requireLock: true });

    try {
      const id = await jobs.queue(forget('snapshot-1'));

      await expect(getJob(id)).resolves.toMatchObject({ status: JobStatus.Queued });
      expect(ctx.resticMock.forget).not.toHaveBeenCalled();
    } finally {
      moduleConfig.update({ requireLock: false });
    }
  });

  it('marks jobs left queued or running as incomplete when the lock holder starts', async () => {
    const jobs = ctx.module.get(JobRepository);
    const queuedId = await insertJob(JobStatus.Queued, new Date('2026-10-13T00:00:00.000Z'));
    const runningId = await insertJob(JobStatus.Running, new Date('2026-10-13T00:00:00.000Z'));

    await jobs.start();

    await expect(getJob(queuedId)).resolves.toMatchObject({ status: JobStatus.Incomplete });
    await expect(getJob(runningId)).resolves.toMatchObject({ status: JobStatus.Incomplete });
  });

  it('publishes a job as it is queued, started and finished', async () => {
    const jobs = ctx.module.get(JobRepository);
    const events: GatewayEvent[] = [];
    const record = (event: GatewayEvent) => events.push(event);
    ctx.events.on(record);

    try {
      const id = await jobs.queue(forget('snapshot-1'));
      await jobs.wait(id);

      expect(
        events.filter(
          (event) =>
            (event.type === 'JobCreate' && event.job.id === id) || (event.type === 'JobUpdate' && event.jobId === id),
        ),
      ).toEqual([
        { type: 'JobCreate', job: expect.objectContaining({ id, status: JobStatus.Queued, repositoryId }) },
        { type: 'JobUpdate', jobId: id, repositoryId, job: expect.objectContaining({ status: JobStatus.Running }) },
        { type: 'JobUpdate', jobId: id, repositoryId, job: expect.objectContaining({ status: JobStatus.Complete }) },
      ]);
    } finally {
      ctx.events.off(record);
    }
  });

  it('reports and publishes the progress of the running job until it finishes', async () => {
    const jobs = ctx.module.get(JobRepository);
    const started = Promise.withResolvers<void>();
    const released = Promise.withResolvers<void>();
    ctx.resticMock.restore.mockImplementationOnce((...args: unknown[]) => {
      const log = args[5] as (event: object) => void;
      log({ message_type: 'status', percent_done: 0.5, total_bytes: 100, bytes_restored: 50 });
      started.resolve();
      return released.promise as never;
    });

    const id = await jobs.queue({
      name: JobName.RepositoryRestore,
      data: { repositoryId, snapshotId: 'snapshot-1', options: {} },
    });
    await started.promise;

    const progress = { percentDone: 0.5, bytesDone: 50, totalBytes: 100, currentFiles: [] };
    await expect(jobs.get(id)).resolves.toMatchObject({ progress });

    const events: GatewayEvent[] = [];
    const record = (event: GatewayEvent) => events.push(event);
    ctx.events.on(record);
    try {
      jobs.publishProgress();
      jobs.publishProgress();
    } finally {
      ctx.events.off(record);
    }

    expect(events).toEqual([{ type: 'JobTick', jobId: id, repositoryId, progress: expect.objectContaining(progress) }]);

    released.resolve();
    await jobs.wait(id);

    await expect(jobs.get(id)).resolves.toMatchObject({ progress: undefined });
  });

  it('keeps a job inserted later but queued earlier behind newer jobs', async () => {
    const jobs = ctx.module.get(JobRepository);

    const newerId = await jobs.queue(forget('snapshot-1'));
    await jobs.wait(newerId);
    const importedId = await insertJob(JobStatus.Complete, new Date('2000-01-01T00:00:00.000Z'));

    const listed = await jobs.getAll(repositoryId);
    const latest = await jobs.getLatest(repositoryId, JobName.RepositorySnapshotForget);

    expect(listed.at(-1)?.id).toBe(importedId);
    expect(latest?.id).not.toBe(importedId);
  });

  it('finds the snapshot of the most recent backup that produced one', async () => {
    const jobs = ctx.module.get(JobRepository);
    const insert = ctx.database.prepare(
      `INSERT INTO jobs (id, name, repositoryId, data, status, outcome, logFilePath, queuedAt)
        VALUES (?, ?, ?, '{}', ?, ?, 'logs/jobs/backup.jsonl', ?)`,
    );

    await expect(jobs.getLastSnapshotId(repositoryId)).resolves.toBeUndefined();

    insert.run(
      'backup-old',
      JobName.RepositoryBackup,
      repositoryId,
      'complete',
      backupOutcome('snapshot-old'),
      '2100-01-01T00:00:00.000Z',
    );
    insert.run(
      'backup-new',
      JobName.RepositoryBackup,
      repositoryId,
      'warn',
      backupOutcome('snapshot-new'),
      '2100-01-02T00:00:00.000Z',
    );
    insert.run(
      'backup-failed',
      JobName.RepositoryBackup,
      repositoryId,
      'failed',
      backupOutcome(),
      '2100-01-03T00:00:00.000Z',
    );
    insert.run(
      'backup-interrupted',
      JobName.RepositoryBackup,
      repositoryId,
      'incomplete',
      null,
      '2100-01-04T00:00:00.000Z',
    );
    insert.run(
      'restore',
      JobName.RepositoryRestore,
      repositoryId,
      'complete',
      backupOutcome('snapshot-restore'),
      '2100-01-05T00:00:00.000Z',
    );

    await expect(jobs.getLastSnapshotId(repositoryId)).resolves.toBe('snapshot-new');

    ctx.database
      .prepare(
        `DELETE FROM jobs WHERE id IN ('backup-old', 'backup-new', 'backup-failed', 'backup-interrupted', 'restore')`,
      )
      .run();
  });

  it('lists the jobs of a repository newest first, without their data', async () => {
    const jobs = ctx.module.get(JobRepository);

    const firstId = await jobs.queue(forget('snapshot-1'));
    const secondId = await jobs.queue(forget('snapshot-2'));
    await jobs.wait(secondId);

    const listed = await jobs.getAll(repositoryId);

    expect(listed.findIndex((job) => job.id === secondId)).toBeLessThan(listed.findIndex((job) => job.id === firstId));
    expect(listed[0]).not.toHaveProperty('data');
  });

  it('runs a job queued by another worker once that worker announces it', async () => {
    const jobs = ctx.module.get(JobRepository);
    const moduleConfig = ctx.module.get(ModuleConfigRepository);
    moduleConfig.update({ requireLock: true });
    const id = await jobs.queue(forget('snapshot-1'));
    moduleConfig.update({ requireLock: false });

    await jobs.onEvent({
      type: 'JobCreate',
      job: { id, name: JobName.RepositorySnapshotForget, repositoryId, status: JobStatus.Queued, queuedAt: '' },
    });

    await expect(jobs.wait(id)).resolves.toMatchObject({ id, status: JobStatus.Complete });
  });

  it('settles a waiter when another worker reports the job finished', async () => {
    const jobs = ctx.module.get(JobRepository);
    const remoteId = await insertJob(JobStatus.Running, new Date('2026-10-14T00:00:00.000Z'));

    const waiting = jobs.wait(remoteId);
    await ctx.db
      .updateTable('futo_backups_jobs')
      .set({ status: JobStatus.Complete })
      .where('id', '=', remoteId)
      .execute();
    await jobs.onEvent({
      type: 'JobUpdate',
      jobId: remoteId,
      repositoryId,
      job: { status: JobStatus.Complete },
    });

    await expect(waiting).resolves.toMatchObject({ id: remoteId, status: JobStatus.Complete });
  });

  it('queues a batch in order and announces every job', async () => {
    const jobs = ctx.module.get(JobRepository);
    const created: string[] = [];
    const record = (event: GatewayEvent) => {
      if (event.type === 'JobCreate') {
        created.push(event.job.id);
      }
    };
    ctx.events.on(record);

    try {
      const ids = await jobs.queueAll([forget('snapshot-1'), forget('snapshot-2'), forget('snapshot-3')]);
      await Promise.all(ids.map((id) => jobs.wait(id)));

      expect(created.filter((id) => ids.includes(id))).toEqual(ids);
      expect(ctx.resticMock.forget.mock.calls.map((call) => call[3])).toEqual([
        'snapshot-1',
        'snapshot-2',
        'snapshot-3',
      ]);
    } finally {
      ctx.events.off(record);
    }
  });

  it('queues nothing for an empty batch', async () => {
    const jobs = ctx.module.get(JobRepository);

    await expect(jobs.queueAll([])).resolves.toEqual([]);
  });

  it('cancels a queued job and rejects its waiters', async () => {
    const jobs = ctx.module.get(JobRepository);
    const release = Promise.withResolvers<void>();
    ctx.resticMock.forget.mockImplementationOnce(() => release.promise as never);

    const runningId = await jobs.queue(forget('snapshot-1'));
    const queuedId = await jobs.queue(forget('snapshot-2'));
    const waiting = jobs.wait(queuedId);

    await jobs.cancel(queuedId);

    await expect(waiting).rejects.toThrow('Cancelled by user action');
    await expect(getJob(queuedId)).resolves.toMatchObject({ status: JobStatus.Cancelled });

    release.resolve();
    await jobs.wait(runningId);
    expect(ctx.resticMock.forget.mock.calls.map((call) => call[3])).toEqual(['snapshot-1']);
  });

  it('stops a running job through its abort signal', async () => {
    const jobs = ctx.module.get(JobRepository);
    const started = blockForgetUntilAborted();

    const id = await jobs.queue(forget('snapshot-1'));
    const waiting = jobs.wait(id);
    await started;

    await jobs.cancel(id);

    await expect(waiting).rejects.toThrow('Cancelled by user action');
    await expect(getJob(id)).resolves.toMatchObject({ status: JobStatus.Cancelled });
  });

  it('stops a running job when another worker asks for the cancel', async () => {
    const jobs = ctx.module.get(JobRepository);
    const started = blockForgetUntilAborted();

    const id = await jobs.queue(forget('snapshot-1'));
    const waiting = jobs.wait(id);
    await started;

    await jobs.onEvent({ type: 'JobCancel', jobId: id });

    await expect(waiting).rejects.toThrow('Cancelled by user action');
  });

  it('rejects cancelling an unknown job', async () => {
    const jobs = ctx.module.get(JobRepository);

    await expect(jobs.cancel(randomUUID())).rejects.toThrow('Job not found');
  });

  it('cancels the jobs of a repository before it is deleted', async () => {
    const jobs = ctx.module.get(JobRepository);
    const repositoryService = ctx.module.get(RepositoryService);
    const { repository } = await repositoryService.createRepository(
      { name: 'Doomed', worm: false, paths: ['/tmp/doomed'] },
      ctx.backendId,
    );
    const started = blockForgetUntilAborted();

    const runningId = await jobs.queue({
      name: JobName.RepositorySnapshotForget,
      data: { repositoryId: repository.id, snapshotId: 'snapshot-1' },
    });
    const queuedId = await jobs.queue({
      name: JobName.RepositorySnapshotForget,
      data: { repositoryId: repository.id, snapshotId: 'snapshot-2' },
    });
    const settling = Promise.allSettled([jobs.wait(runningId), jobs.wait(queuedId)]);
    await started;

    await repositoryService.deleteRepository(repository.id);

    const settled = await settling;
    expect(settled.map((result) => result.status)).toEqual(['rejected', 'rejected']);
    expect(await jobs.getAll(repository.id)).toEqual([]);
  });
});

describe('support sessions', () => {
  it('makes repository deletion wait for a job that is still finishing its support session', async () => {
    const jobs = ctx.module.get(JobRepository);
    const repositoryService = ctx.module.get(RepositoryService);
    await ctx.module
      .get(ConfigRepository)
      .setSupportMode({ remainingRuns: 1, streamToFuto: false, includePaths: false });
    const { repository } = await repositoryService.createRepository(
      { name: 'Finishing', worm: false, paths: ['/tmp/finishing'] },
      ctx.backendId,
    );
    const finishing = Promise.withResolvers<void>();
    const release = Promise.withResolvers<void>();
    const finish = jest.spyOn(SupportSession.prototype, 'finish').mockImplementationOnce(async () => {
      finishing.resolve();
      await release.promise;
      return { sessionId: undefined, droppedLines: 0, localDroppedLines: 0 };
    });

    try {
      const jobId = await jobs.queue({
        name: JobName.RepositorySnapshotForget,
        data: { repositoryId: repository.id, snapshotId: 'snapshot-1' },
      });
      const settled = jobs.wait(jobId).catch(() => undefined);
      await finishing.promise;

      let deleted = false;
      const deletion = repositoryService.deleteRepository(repository.id).then(() => (deleted = true));
      await new Promise((resolve) => setTimeout(resolve, 100));
      expect(deleted).toBe(false);

      release.resolve();
      await deletion;
      await settled;

      expect(await jobs.getAll(repository.id)).toEqual([]);
    } finally {
      finish.mockRestore();
    }
  });

  it('runs a job in support mode once per remaining run and keeps its verbose log next to the job log', async () => {
    const jobs = ctx.module.get(JobRepository);
    const config = ctx.module.get(ConfigRepository);
    await config.setSupportMode({ remainingRuns: 1, streamToFuto: false, includePaths: false });

    const supported = await jobs.queue(forget('snapshot-1'));
    await jobs.wait(supported);
    const unsupported = await jobs.queue(forget('snapshot-1'));
    await jobs.wait(unsupported);

    const supportedJob = await getJob(supported);
    const unsupportedJob = await getJob(unsupported);
    expect(supportedJob.outcome).toMatchObject({
      support: { droppedLines: 0, localDroppedLines: 0 },
    });
    expect(unsupportedJob.outcome).not.toHaveProperty('support');
    await expect(access(join(ctx.statePath, 'logs', 'jobs', `${supported}.support.jsonl`))).resolves.toBeUndefined();
    await expect(access(join(ctx.statePath, 'logs', 'jobs', `${unsupported}.support.jsonl`))).rejects.toThrow();
    await expect(config.getSupportMode()).resolves.toMatchObject({ remainingRuns: 0 });
  });
});
