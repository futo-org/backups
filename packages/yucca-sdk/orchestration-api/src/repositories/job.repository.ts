import { BeforeApplicationShutdown, Injectable, NotFoundException, OnModuleInit } from '@nestjs/common';
import { DiscoveryService, Reflector } from '@nestjs/core';
import { EventIterator } from 'event-iterator';
import { Kysely, Selectable, sql, UpdateQueryBuilder, UpdateResult } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { from } from 'rxjs';
import { Tail } from 'tail';
import { JobConfig } from '../decorators.js';
import { JobDto } from '../dto/job.dto.js';
import { JobName, JobStatus, MetadataKey } from '../enum.js';
import { EventsGateway, GatewayEvent } from '../events/events.gateway.js';
import { JobContext } from '../jobs/jobContext.js';
import { DB } from '../schema/index.js';
import { JobTable } from '../schema/tables/job.table.js';
import { getJobStatus, TaskCancelledError, writeError } from '../utils/errors.js';
import type { JobHandler, JobItem } from '../utils/types.js';
import { LoggingRepository } from './logging.repository.js';
import { ModuleConfigRepository } from './moduleConfig.repository.js';
import { StorageRepository } from './storage.repository.js';

export type Job = Selectable<JobTable>;

const toJobDto = ({ data: _data, logFilePath: _logFilePath, ...job }: Job): JobDto => job;

const finishedStatuses = new Set([JobStatus.Complete, JobStatus.Warn, JobStatus.Failed, JobStatus.Cancelled]);

@Injectable()
export class JobRepository implements OnModuleInit, BeforeApplicationShutdown {
  private handlers = new Map<JobName, { label: string; handler: JobHandler<unknown> }>();

  private dispatching?: Promise<void>;
  private running?: { id: string; repositoryId: string; controller: AbortController };
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
    await this.storage.mkdir(dirname(logFilePath), { recursive: true });

    return new JobContext(signal, this.storage.createWriteStream(logFilePath));
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

    return job && toJobDto(job);
  }

  private find(id: string) {
    return this.db.selectFrom('jobs').selectAll().where('id', '=', id).executeTakeFirst();
  }

  async getAll(repositoryId: string) {
    const jobs = await this.db
      .selectFrom('jobs')
      .selectAll()
      .where('repositoryId', '=', repositoryId)
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
      .orderBy(sql`rowid`, 'desc')
      .limit(1)
      .executeTakeFirst();

    return job && toJobDto(job);
  }

  getObservable(id: string) {
    return from(
      new EventIterator<MessageEvent>((queue) => {
        let tail: Tail | undefined;
        let logFilePath = '';

        this.getLogFilePath(id)
          .then((path) => {
            if (!path) {
              throw new NotFoundException('Job not found');
            }

            logFilePath = path;
          })
          .then(() => this.storage.mkdir(dirname(logFilePath), { recursive: true }))
          .then(() => this.storage.touch(logFilePath))
          .then(() => {
            tail = new Tail(logFilePath, { fromBeginning: true, nLines: 50 });
            tail.on('line', (data) => queue.push({ data } as MessageEvent));
            tail.on('error', (error) => {
              this.logger.warn(`tail ${logFilePath} stopped:`, error);
              tail?.unwatch();
            });
          })
          .catch(queue.fail);

        return () => {
          tail?.unwatch();
        };
      }),
    );
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
    const job = await this.find(id);
    if (!job) {
      throw new NotFoundException('Job not found');
    }

    await this.cancelQueued((eb) => eb('id', '=', id));

    if (job.status === JobStatus.Running && !this.abort(id)) {
      this.events.publish({ type: 'JobCancel', jobId: id });
    }
  }

  async cancelAll(repositoryId: string) {
    await this.cancelQueued((eb) => eb('repositoryId', '=', repositoryId));

    if (this.running?.repositoryId === repositoryId) {
      this.abort(this.running.id);
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
      waiter.reject(error ?? new Error(job.error ?? job.status));
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

    let error: unknown;
    try {
      await handler.run(JSON.parse(job.data), ctx);
    } catch (error_) {
      error = error_;
      writeError(ctx.logWriter, error);
    }

    await new Promise<void>((done) => ctx.logWriter.end(done));

    const updateSet = {
      status: getJobStatus(error),
      error: error ? `${error}` : undefined,
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
      job: { status: job.status, error: job.error, end: job.end },
    });

    this.settle(job, error);
  }
}
