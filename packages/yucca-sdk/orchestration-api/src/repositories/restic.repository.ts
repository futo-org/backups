import {
  backup,
  type BackupMessage,
  forget,
  init,
  keyList,
  ls,
  prune,
  restore,
  type RestoreMessage,
  snapshots,
  stats,
  unlock,
} from '@futo-org/restic-wrapper';
import { Injectable } from '@nestjs/common';
import type { ChildProcess } from 'node:child_process';
import { RepositorySnapshotRestoreRequestDto } from '../dto/repository.dto.js';
import { createSampledLogWriter, RetentionPolicy } from '../utils/restic.js';
import { ConfigRepository, ResticPlacement } from './config.repository.js';
import { ModuleConfigRepository } from './moduleConfig.repository.js';
import { SupportContextRepository } from './supportContext.repository.js';

type Traceable = {
  verbose(level?: boolean | number): unknown;
  on(event: 'process', listener: (process: ChildProcess) => void): unknown;
};

@Injectable()
export class ResticRepository {
  constructor(
    private readonly config: ConfigRepository,
    private readonly moduleConfig: ModuleConfigRepository,
    private readonly supportContext: SupportContextRepository,
  ) {}

  private get cacheDir() {
    return this.moduleConfig.get().cachePath;
  }

  private traced<T extends Traceable>(command: string, builder: T): T {
    const session = this.supportContext.current();
    if (session) {
      builder.verbose(session.verbosity);
      builder.on('process', (process) => session.attach(process, command));
    }

    return builder;
  }

  async init(repository: string, key: Uint8Array, placement: ResticPlacement) {
    const { connections } = await this.config.getResticOptions(placement);
    await this.traced('init', init())
      .option(`rest.connections=${connections}`)
      .repository(repository)
      .cacheDir(this.cacheDir)
      .password(Buffer.from(key).toString('hex'))
      .run();
  }

  async backup(
    repository: string,
    key: Uint8Array,
    placement: ResticPlacement,
    paths: string[],
    log?: (event: BackupMessage) => void,
    signal?: AbortSignal,
    tags: string[] = [],
    parent?: string,
  ) {
    const write = createSampledLogWriter(log);
    const { connections, packSizeMib } = await this.config.getResticOptions(placement);

    // restic's default parent match includes the hostname, which in a container changes on every recreate and
    // would force a full re-read.
    return await this.traced('backup', backup())
      .option(`rest.connections=${connections}`)
      .packSize(packSizeMib)
      .repository(repository)
      .cacheDir(this.cacheDir)
      .password(Buffer.from(key).toString('hex'))
      .tag(...tags)
      .groupBy('paths')
      .parent(parent)
      .walkConcurrency(this.moduleConfig.get().resticWalkConcurrency)
      .addFile(...paths)
      .excludeCaches()
      .signal(signal)
      .on('event', write)
      .run();
  }

  async restore(
    repository: string,
    key: Uint8Array,
    placement: ResticPlacement,
    snapshotId: string,
    { include, target }: RepositorySnapshotRestoreRequestDto,
    log?: (event: RestoreMessage) => void,
    signal?: AbortSignal,
  ) {
    const write = createSampledLogWriter(log);
    const { connections } = await this.config.getResticOptions(placement);

    let command = this.traced('restore', restore())
      .option(`rest.connections=${connections}`)
      .repository(repository)
      .cacheDir(this.cacheDir)
      .password(Buffer.from(key).toString('hex'))
      .snapshot(snapshotId)
      .target(target ?? '/')
      .signal(signal)
      .on('event', write);

    if (include) {
      command = command.include(...include);
    }

    return await command.run();
  }

  async ls(repository: string, key: Uint8Array, placement: ResticPlacement, snapshotId: string, path: string) {
    const { connections } = await this.config.getResticOptions(placement);
    return await this.traced('ls', ls())
      .option(`rest.connections=${connections}`)
      .repository(repository)
      .cacheDir(this.cacheDir)
      .password(Buffer.from(key).toString('hex'))
      .snapshot(snapshotId)
      .directory(path)
      .noLock()
      .run();
  }

  async stats(repository: string, key: Uint8Array, placement: ResticPlacement, signal?: AbortSignal) {
    const { connections } = await this.config.getResticOptions(placement);
    return await this.traced('stats', stats())
      .option(`rest.connections=${connections}`)
      .repository(repository)
      .cacheDir(this.cacheDir)
      .password(Buffer.from(key).toString('hex'))
      .signal(signal)
      .modeRawData()
      .run();
  }

  async snapshots(repository: string, key: Uint8Array, placement: ResticPlacement) {
    const { connections } = await this.config.getResticOptions(placement);
    return await this.traced('snapshots', snapshots())
      .option(`rest.connections=${connections}`)
      .noLock()
      .repository(repository)
      .cacheDir(this.cacheDir)
      .password(Buffer.from(key).toString('hex'))
      .run();
  }

  async snapshot(
    repository: string,
    key: Uint8Array,
    placement: ResticPlacement,
    snapshotId: string,
    signal?: AbortSignal,
  ) {
    const { connections } = await this.config.getResticOptions(placement);
    return await this.traced('snapshots', snapshots())
      .option(`rest.connections=${connections}`)
      .noLock()
      .repository(repository)
      .cacheDir(this.cacheDir)
      .password(Buffer.from(key).toString('hex'))
      .snapshot(snapshotId)
      .signal(signal)
      .run();
  }

  async forget(
    repository: string,
    key: Uint8Array,
    placement: ResticPlacement,
    snapshotId: string,
    prune = true,
    signal?: AbortSignal,
  ) {
    const { connections } = await this.config.getResticOptions(placement);
    return await this.traced('forget', forget())
      .option(`rest.connections=${connections}`)
      .repository(repository)
      .cacheDir(this.cacheDir)
      .password(Buffer.from(key).toString('hex'))
      .snapshot(snapshotId)
      .prune(prune)
      .signal(signal)
      .run();
  }

  async forgetByPolicy(
    repository: string,
    key: Uint8Array,
    placement: ResticPlacement,
    policy: RetentionPolicy,
    signal?: AbortSignal,
  ) {
    const { connections } = await this.config.getResticOptions(placement);
    // Policies are measured from each group's newest snapshot, so grouping by the container's hostname leaves the
    // snapshots of every previous container in a group that never expires.
    return await this.traced('forget', forget())
      .option(`rest.connections=${connections}`)
      .repository(repository)
      .cacheDir(this.cacheDir)
      .password(Buffer.from(key).toString('hex'))
      .signal(signal)
      .groupBy('paths')
      .keepLast(policy.keepLast)
      .keepWithin(policy.keepWithin)
      .keepWithinHourly(policy.keepWithinHourly)
      .keepWithinDaily(policy.keepWithinDaily)
      .keepWithinWeekly(policy.keepWithinWeekly)
      .keepWithinMonthly(policy.keepWithinMonthly)
      .keepWithinYearly(policy.keepWithinYearly)
      .run();
  }

  async prune(repository: string, key: Uint8Array, placement: ResticPlacement, signal?: AbortSignal) {
    const { connections, packSizeMib } = await this.config.getResticOptions(placement);
    return await this.traced('prune', prune())
      .option(`rest.connections=${connections}`)
      .packSize(packSizeMib)
      .repository(repository)
      .cacheDir(this.cacheDir)
      .password(Buffer.from(key).toString('hex'))
      .signal(signal)
      .run();
  }

  async keyList(repository: string, key: Uint8Array, placement: ResticPlacement) {
    const { connections } = await this.config.getResticOptions(placement);
    return await this.traced('key list', keyList())
      .option(`rest.connections=${connections}`)
      .repository(repository)
      .cacheDir(this.cacheDir)
      .password(Buffer.from(key).toString('hex'))
      .run();
  }

  async unlockAll(repository: string, key: Uint8Array, placement: ResticPlacement) {
    const { connections } = await this.config.getResticOptions(placement);
    return await this.traced('unlock', unlock())
      .option(`rest.connections=${connections}`)
      .removeAll()
      .repository(repository)
      .cacheDir(this.cacheDir)
      .password(Buffer.from(key).toString('hex'))
      .run();
  }
}
