import { cp, mkdir, mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { JobName, JobStatus } from '../src/enum.js';
import { type GatewayEvent } from '../src/events/events.gateway.js';
import { JobRepository } from '../src/repositories/job.repository.js';
import { ModuleConfigRepository } from '../src/repositories/moduleConfig.repository.js';
import { RepositoryService } from '../src/services/repository.service.js';
import { createTestingModule, TestContext } from './testUtils.js';

let ctx: TestContext;
let repositoryId: string;

const forget = (snapshotId: string) =>
  ({ name: JobName.RepositorySnapshotForget, data: { repositoryId, snapshotId } }) as const;

const getJob = (id: string) =>
  ctx.database.prepare('SELECT * FROM jobs WHERE id = ?').get(id) as { status: JobStatus; error: string | null };

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
    expect(getJob(id)).toMatchObject({ status: JobStatus.Failed, error: 'Error: restic forget failed' });

    const log = await readFile(join(ctx.statePath, 'logs', 'jobs', `${id}.jsonl`), 'utf8');
    expect(log).toContain('restic forget failed');
  });

  it('runs one job at a time in queue order', async () => {
    const jobs = ctx.module.get(JobRepository);
    const first = Promise.withResolvers<void>();
    ctx.resticMock.forget.mockImplementationOnce(() => first.promise as never);

    const firstId = await jobs.queue(forget('snapshot-1'));
    const secondId = await jobs.queue(forget('snapshot-2'));

    expect(getJob(firstId).status).toBe(JobStatus.Running);
    expect(getJob(secondId).status).toBe(JobStatus.Queued);

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

      expect(getJob(id).status).toBe(JobStatus.Queued);
      expect(ctx.resticMock.forget).not.toHaveBeenCalled();
    } finally {
      moduleConfig.update({ requireLock: false });
    }
  });

  it('fails jobs left queued or running when the lock holder starts', async () => {
    const jobs = ctx.module.get(JobRepository);
    ctx.database
      .prepare(
        `INSERT INTO jobs (id, name, repositoryId, data, status, logFilePath, queuedAt) VALUES
          ('leftover-queued', ?, ?, '{}', 'queued', 'logs/jobs/leftover-queued.jsonl', '2026-10-13T00:00:00.000Z'),
          ('leftover-running', ?, ?, '{}', 'running', 'logs/jobs/leftover-running.jsonl', '2026-10-13T00:00:00.000Z')`,
      )
      .run(JobName.RepositorySnapshotForget, repositoryId, JobName.RepositorySnapshotForget, repositoryId);

    await jobs.start();

    expect(getJob('leftover-queued').status).toBe(JobStatus.Failed);
    expect(getJob('leftover-running').status).toBe(JobStatus.Failed);
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
    ctx.database
      .prepare(
        `INSERT INTO jobs (id, name, repositoryId, data, status, logFilePath, queuedAt)
          VALUES ('remote-job', ?, ?, '{}', 'running', 'logs/jobs/remote-job.jsonl', '2026-10-14T00:00:00.000Z')`,
      )
      .run(JobName.RepositorySnapshotForget, repositoryId);

    const waiting = jobs.wait('remote-job');
    ctx.database.prepare(`UPDATE jobs SET status = 'complete' WHERE id = 'remote-job'`).run();
    await jobs.onEvent({
      type: 'JobUpdate',
      jobId: 'remote-job',
      repositoryId,
      job: { status: JobStatus.Complete },
    });

    await expect(waiting).resolves.toMatchObject({ id: 'remote-job', status: JobStatus.Complete });
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
    expect(getJob(queuedId).status).toBe(JobStatus.Cancelled);

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
    expect(getJob(id).status).toBe(JobStatus.Cancelled);
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

    await expect(jobs.cancel('missing')).rejects.toThrow('Job not found');
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

const restorePoint = async (failStateRestore = false) => {
  const previousInstall = await mkdtemp(join(tmpdir(), 'yucca-previous-'));
  await mkdir(join(previousInstall, 'state'));
  ctx.database.prepare(`INSERT INTO config (key, value) VALUES ('restored-marker', 'yes')`).run();
  await ctx.database.backup(join(previousInstall, 'state', 'state.sqlite3'));
  ctx.database.prepare(`DELETE FROM config WHERE key = 'restored-marker'`).run();

  ctx.resticMock.restore.mockImplementation((async (...args: unknown[]) => {
    const { target } = args[4] as { target?: string };
    if (!target) {
      return;
    }

    if (failStateRestore) {
      throw new Error('restic restore failed');
    }

    await cp(join(previousInstall, 'state'), join(target, 'state'), { recursive: true });
  }) as never);

  const { jobId } = await ctx.module
    .get(RepositoryService)
    .restoreFromPoint('remote-repository', 'snapshot-1', ctx.backendId, {
      include: ['/photos'],
      yuccaConfig: 'state',
    });

  return jobId;
};

const marker = () => ctx.database.prepare(`SELECT value FROM config WHERE key = 'restored-marker'`).get();

describe('restore from point', () => {
  afterEach(() => {
    ctx.resticMock.restore.mockReset();
    ctx.database.prepare(`DELETE FROM config WHERE key = 'restored-marker'`).run();
  });

  it('restores the files and the previous install state for a repository not yet known locally', async () => {
    const jobs = ctx.module.get(JobRepository);

    const jobId = await restorePoint();
    await expect(jobs.wait(jobId)).resolves.toMatchObject({ id: jobId, status: JobStatus.Complete });

    expect(ctx.resticMock.restore).toHaveBeenCalledWith(
      expect.anything(),
      expect.anything(),
      expect.anything(),
      'snapshot-1',
      { include: ['/photos'] },
      expect.anything(),
      expect.any(AbortSignal),
    );
    expect(marker()).toEqual({ value: 'yes' });
    expect(getJob(jobId)).toMatchObject({ status: JobStatus.Complete });
  });

  it('fails without touching the current state when the state restore fails', async () => {
    const jobs = ctx.module.get(JobRepository);

    const jobId = await restorePoint(true);
    await expect(jobs.wait(jobId)).rejects.toThrow('restic restore failed');

    expect(marker()).toBeUndefined();
    expect(getJob(jobId)).toMatchObject({ status: JobStatus.Failed });
  });
});
