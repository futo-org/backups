import { BeforeApplicationShutdown, Injectable, NotFoundException, OnModuleInit } from '@nestjs/common';
import { DiscoveryService, Reflector } from '@nestjs/core';
import { Interval } from '@nestjs/schedule';
import { Kysely, Selectable, sql, UpdateQueryBuilder, UpdateResult } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { Writable } from 'node:stream';
import { JobConfig } from '../decorators.js';
import { JobDto, JobProgressDto } from '../dto/job.dto.js';
import { JobName, JobStatus, MetadataKey } from '../enum.js';
import { EventsGateway, GatewayEvent } from '../events/events.gateway.js';
import { JobContext } from '../jobs/jobContext.js';
import { DB } from '../schema/index.js';
import { JobTable } from '../schema/tables/job.table.js';
import { SupportModeService } from '../services/supportMode.service.js';
import { TelemetryService } from '../services/telemetry.service.js';
import { getJobStatus, TaskCancelledError, writeError } from '../utils/errors.js';
import type { JobHandler, JobItem } from '../utils/types.js';
import { LoggingRepository } from './logging.repository.js';
import { ModuleConfigRepository } from './moduleConfig.repository.js';
import { StorageRepository } from './storage.repository.js';
import { SupportContextRepository } from './supportContext.repository.js';

export type Job = Selectable<JobTable>;

const toJobDto = ({ data: _data, logFilePath: _logFilePath, outcome, ...job }: Job): JobDto => ({
  ...job,
  outcome: outcome ? JSON.parse(outcome) : undefined,
});

const finishedStatuses = new Set([JobStatus.Complete, JobStatus.Warn, JobStatus.Failed, JobStatus.Cancelled]);

@Injectable()
export class JobRepository implements OnModuleInit, BeforeApplicationShutdown {
  private handlers = new Map<JobName, { label: string; handler: JobHandler<unknown> }>();

  private dispatching?: Promise<void>;
  private running?: {
    id: string;
    repositoryId: string;
    controller: AbortController;
    ctx?: JobContext;
    lastProgressTick?: JobProgressDto;
  };
  private stopped = false;
  private activeJobs = new Map<string, PromiseWithResolvers<Job>>();

  constructor(
    @InjectKysely('orchestrator') private db: Kysely<DB>,
    private readonly discovery: DiscoveryService,
    private readonly reflector: Reflector,
    private readonly moduleConfig: ModuleConfigRepository,
    private readonly storage: StorageRepository,
    private readonly events: EventsGateway,
    private readonly logger: LoggingRepository,
    private readonly telemetry: TelemetryService,
    private readonly supportMode: SupportModeService,
    private readonly supportContext: SupportContextRepository,
  ) {
    this.logger.setContext(JobRepository.name);
  }

  onModuleInit() {
    this.handlers.clear();

    for (const { instance, metatype } of this.discovery.getProviders()) {
      if (!metatype) {
        continue;
      }

      const config = this.reflector.get<JobConfig | undefined>(MetadataKey.JobConfig, metatype);
      if (!config) {
        continue;
      }

      const label = metatype.name;
      const existing = this.handlers.get(config.name);
      if (existing) {
        throw new Error(
          `Failed to add job handler for ${label}, ${config.name} is already handled by ${existing.label}`,
        );
      }

      this.handlers.set(config.name, { label, handler: instance as JobHandler<unknown> });
    }

    for (const name of Object.values(JobName)) {
      if (!this.handlers.has(name)) {
        throw new Error(`Failed to find job handler for ${name}`);
      }
    }
  }

  async start() {
    if (!this.moduleConfig.hasLock()) {
      return [];
    }

    return this.db
      .updateTable('jobs')
      .set({ status: JobStatus.Incomplete, end: new Date().toISOString() })
      .where('status', 'in', [JobStatus.Queued, JobStatus.Running])
      .returningAll()
      .execute();
  }

  async getLogFilePath(id: string) {
    const job = await this.find(id);

    return job && this.resolveLogFilePath(job);
  }

  private resolveLogFilePath(job: Job) {
    return resolve(this.moduleConfig.get().statePath, job.logFilePath);
  }

  private async createCtx(job: Job, signal: AbortSignal) {
    const logFilePath = this.resolveLogFilePath(job);

    try {
      await this.storage.mkdir(dirname(logFilePath), { recursive: true });
    } catch (error) {
      this.logger.warn(`Logging is unavailable for job ${job.id}, running it without a log`, error);
      this.telemetry.submitStructuredLog('Logging is unavailable for job', { jobId: job.id, error });
      return new JobContext(signal, new Writable({ write: (_chunk, _encoding, done) => done() }));
    }

    return new JobContext(signal, this.storage.createWriteStream(logFilePath));
  }

  private async beginSupportSession(job: Job) {
    try {
      return await this.supportMode.begin(job, this.resolveLogFilePath(job));
    } catch (error) {
      this.logger.warn(`Support mode is unavailable for job ${job.id}, running it without`, error);
    }
  }

  async queue(item: JobItem) {
    const [id] = await this.queueAll([item]);

    return id;
  }

  async queueAll(items: JobItem[]) {
    if (items.length === 0) {
      return [];
    }

    const queuedAt = new Date().toISOString();
    const jobs = await this.db
      .insertInto('jobs')
      .values(
        items.map(({ name, data }) => {
          const id = randomUUID();

          return {
            id,
            name,
            repositoryId: data.repositoryId,
            data: JSON.stringify(data),
            status: JobStatus.Queued,
            logFilePath: join('logs', 'jobs', `${id}.jsonl`),
            queuedAt,
          };
        }),
      )
      .returningAll()
      .execute();

    for (const job of jobs) {
      this.events.publish({ type: 'JobCreate', job: toJobDto(job) });
    }

    void this.dispatch();

    return jobs.map((job) => job.id);
  }

  async get(id: string) {
    const job = await this.find(id);
    if (!job) {
      return;
    }

    return { ...toJobDto(job), progress: this.running?.id === id ? this.running.ctx?.progress : undefined };
  }

  private find(id: string) {
    return this.db.selectFrom('jobs').selectAll().where('id', '=', id).executeTakeFirst();
  }

  async getAll(repositoryId: string) {
    const jobs = await this.db
      .selectFrom('jobs')
      .selectAll()
      .where('repositoryId', '=', repositoryId)
      .orderBy('queuedAt', 'desc')
      .orderBy(sql`rowid`, 'desc')
      .execute();

    return jobs.map((job) => toJobDto(job));
  }

  async getLatest(repositoryId: string, name: JobName) {
    const job = await this.db
      .selectFrom('jobs')
      .selectAll()
      .where('repositoryId', '=', repositoryId)
      .where('name', '=', name)
      .orderBy('queuedAt', 'desc')
      .orderBy(sql`rowid`, 'desc')
      .limit(1)
      .executeTakeFirst();

    return job && toJobDto(job);
  }

  async onEvent(event: GatewayEvent) {
    if (event.type === 'JobCreate') {
      void this.dispatch();
      return;
    }

    if (event.type === 'JobCancel') {
      this.abort(event.jobId);
      return;
    }

    if (
      event.type === 'JobUpdate' &&
      event.job.status &&
      finishedStatuses.has(event.job.status) &&
      this.activeJobs.has(event.jobId)
    ) {
      const job = await this.find(event.jobId);
      if (job) {
        this.settle(job);
      }
    }
  }

  async cancel(id: string) {
    const [cancelled] = await this.cancelQueued((eb) => eb('id', '=', id));
    if (cancelled) {
      return;
    }

    const job = await this.find(id);
    if (!job) {
      throw new NotFoundException('Job not found');
    }

    if (job.status === JobStatus.Running && !this.abort(id)) {
      this.events.publish({ type: 'JobCancel', jobId: id });
    }
  }

  async cancelAll(repositoryId: string) {
    await this.cancelQueued((eb) => eb('repositoryId', '=', repositoryId));

    const running = await this.db
      .selectFrom('jobs')
      .select('id')
      .where('repositoryId', '=', repositoryId)
      .where('status', '=', JobStatus.Running)
      .execute();

    for (const { id } of running) {
      if (!this.abort(id)) {
        this.events.publish({ type: 'JobCancel', jobId: id });
      }
    }

    if (this.running?.repositoryId === repositoryId) {
      await this.wait(this.running.id).catch(() => {});
    }
  }

  private async cancelQueued(where: Parameters<UpdateQueryBuilder<DB, 'jobs', 'jobs', UpdateResult>['where']>[0]) {
    const cancelled = await this.db
      .updateTable('jobs')
      .set({ status: JobStatus.Cancelled, end: new Date().toISOString() })
      .where('status', '=', JobStatus.Queued)
      .where(where)
      .returningAll()
      .execute();

    for (const job of cancelled) {
      this.events.publish({
        type: 'JobUpdate',
        jobId: job.id,
        repositoryId: job.repositoryId,
        job: { status: job.status, end: job.end },
      });

      this.settle(job, new TaskCancelledError());
    }

    return cancelled;
  }

  private abort(id: string) {
    if (this.running?.id !== id) {
      return false;
    }

    this.running.controller.abort(new TaskCancelledError());

    return true;
  }

  async wait(id: string) {
    let waiter = this.activeJobs.get(id);
    if (!waiter) {
      waiter = Promise.withResolvers<Job>();
      this.activeJobs.set(id, waiter);
    }

    const job = await this.find(id);
    if (!job) {
      throw new NotFoundException('Job not found');
    }

    this.settle(job);

    return waiter.promise;
  }

  private settle(job: Job, error?: unknown) {
    const waiter = this.activeJobs.get(job.id);
    if (!waiter || job.status === JobStatus.Queued || job.status === JobStatus.Running) {
      return;
    }

    this.activeJobs.delete(job.id);

    if (job.status === JobStatus.Complete) {
      waiter.resolve(job);
    } else {
      waiter.reject(error ?? new Error(toJobDto(job).outcome?.errors.at(-1) ?? job.status));
    }
  }

  async beforeApplicationShutdown() {
    this.stopped = true;
    this.running?.controller.abort(new TaskCancelledError());
    await this.dispatching;
  }

  private async dispatch() {
    if (this.dispatching || this.stopped || !this.moduleConfig.hasLock()) {
      return;
    }

    const { promise, resolve } = Promise.withResolvers<void>();
    this.dispatching = promise;

    try {
      while (!this.stopped) {
        const job = await this.claim();
        if (!job) {
          break;
        }

        await this.run(job);
      }
    } finally {
      this.dispatching = undefined;
      resolve();
    }
  }

  private async claim() {
    const job = await this.db
      .updateTable('jobs')
      .set({ status: JobStatus.Running, start: new Date().toISOString() })
      .where('id', '=', (eb) =>
        eb
          .selectFrom('jobs')
          .select('id')
          .where('status', '=', JobStatus.Queued)
          .orderBy(sql`rowid`)
          .limit(1),
      )
      .returningAll()
      .executeTakeFirst();

    if (job) {
      this.events.publish({
        type: 'JobUpdate',
        jobId: job.id,
        repositoryId: job.repositoryId,
        job: { status: job.status, start: job.start },
      });
    }

    return job;
  }

  private async run(job: Job) {
    this.logger.log(`Running job ${job.name} id=${job.id}`);

    const { handler } = this.handlers.get(job.name)!;
    this.running = { id: job.id, repositoryId: job.repositoryId, controller: new AbortController() };

    const ctx = await this.createCtx(job, this.running.controller.signal);
    this.running.ctx = ctx;

    const support = await this.beginSupportSession(job);

    let error: unknown;
    try {
      try {
        await this.supportContext.run(support, () => handler.run(JSON.parse(job.data), ctx));
      } catch (error_) {
        error = error_;
        writeError((event) => ctx.log(event), error);
      }

      if (support) {
        ctx.outcome.support = await support.finish();
      }
    } finally {
      this.running = undefined;
    }

    await new Promise<void>((done) => ctx.logWriter.end(done));

    const updateSet = {
      status: getJobStatus(error),
      outcome: JSON.stringify(ctx.outcome),
      end: new Date().toISOString(),
    };

    job = await this.db
      .insertInto('jobs')
      .values({
        ...job,
        ...updateSet,
      })
      .onConflict((oc) => oc.column('id').doUpdateSet(updateSet))
      .returningAll()
      .executeTakeFirstOrThrow();

    this.events.publish({
      type: 'JobUpdate',
      jobId: job.id,
      repositoryId: job.repositoryId,
      job: { status: job.status, outcome: ctx.outcome, end: job.end },
    });

    this.settle(job, error);
  }

  @Interval(1000)
  publishProgress() {
    const progress = this.running?.ctx?.progress;
    if (!this.running || !progress || progress === this.running.lastProgressTick) {
      return;
    }

    this.running.lastProgressTick = progress;
    this.events.publish({ type: 'JobTick', jobId: this.running.id, repositoryId: this.running.repositoryId, progress });
  }
}
