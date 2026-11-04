import { Injectable, OnApplicationBootstrap, OnApplicationShutdown } from '@nestjs/common';
import type { ChildProcess } from 'node:child_process';
import { mkdir, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { ResticArchiveTag, ResticTagPrefix } from '../enum.js';
import type { ImmichWalArchiving } from '../moduleConfig.js';
import { LoggingRepository } from '../repositories/logging.repository.js';
import { ModuleConfigRepository } from '../repositories/moduleConfig.repository.js';
import { type PostgresClient, PostgresRepository } from '../repositories/postgres.repository.js';
import { RepositoryIntegrationImmichRepository } from '../repositories/repositoryIntegrationImmich.repository.js';
import { ResticRepository } from '../repositories/restic.repository.js';
import {
  getTagValue,
  selectWalFilesToPrune,
  selectWalFilesToShip,
  type WalFile,
  type WalShipState,
} from '../utils/wal.js';
import { RepositoryService } from './repository.service.js';

const DEFAULT_SLOT_NAME = 'futo_backups';
const DEFAULT_MAX_SLOT_WAL_KEEP_SIZE = '8GB';
const DEFAULT_SHIP_INTERVAL_MS = 60_000;
const DEFAULT_BASE_BACKUP_INTERVAL_MS = 24 * 60 * 60 * 1000;
const DEFAULT_SEGMENT_SHIPPED_TIMEOUT_MS = 5 * 60 * 1000;
const SEGMENT_POLL_INTERVAL_MS = 500;
const BASE_BACKUP_FILENAME = 'immich-base.tar';
const RECEIVER_STDERR_LIMIT = 4096;

type WalArchive = { config: ImmichWalArchiving; repositoryId: string };

export type WalBaseBackup = { startLsn: string; stopLsn: string };

@Injectable()
export class ImmichWalService implements OnApplicationBootstrap, OnApplicationShutdown {
  private receiver?: ChildProcess;
  private receiverStarting?: Promise<void>;
  private timer?: NodeJS.Timeout;
  private stopped = false;
  private serial: Promise<unknown> = Promise.resolve();
  private baseRequired = false;
  private client?: { config: ImmichWalArchiving; client: Promise<PostgresClient> };

  constructor(
    private readonly moduleConfig: ModuleConfigRepository,
    private readonly repositoryIntegrationImmich: RepositoryIntegrationImmichRepository,
    private readonly repositoryService: RepositoryService,
    private readonly restic: ResticRepository,
    private readonly postgres: PostgresRepository,
    private readonly logger: LoggingRepository,
  ) {
    this.logger.setContext(ImmichWalService.name);
  }

  onApplicationBootstrap() {
    this.schedule();
  }

  async onApplicationShutdown() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.stopReceiver();
    await this.serial;
  }

  async isEnabledFor(repositoryId: string) {
    const archive = await this.getArchive();
    return archive?.repositoryId === repositoryId;
  }

  async tick() {
    const archive = await this.getArchive();
    if (!archive || !this.moduleConfig.hasLock()) {
      this.stopReceiver();
      return;
    }

    try {
      await this.ensureReceiver(archive);
      await this.ship(archive, archive.config.shipPartial ?? true);
    } catch (error) {
      this.logger.warn(`WAL archiving failed, retrying on the next tick: ${error}`);
    }
  }

  async backupBaseIfDue(signal?: AbortSignal, force = false): Promise<WalBaseBackup | undefined> {
    const archive = await this.getArchiveOrThrow();
    await this.ensureReceiver(archive);

    if (!force && !this.baseRequired && !(await this.isBaseBackupStale(archive))) {
      return;
    }

    return await this.backupBase(archive, signal);
  }

  async prepareSnapshot(label: string, signal?: AbortSignal): Promise<string> {
    const archive = await this.getArchiveOrThrow();
    await this.ensureReceiver(archive);

    const client = await this.getClient(archive.config);
    const [[lsn, segment]] = await this.postgres.query(
      client,
      `SELECT lsn, pg_walfile_name(lsn) FROM pg_create_restore_point(:'label') AS lsn`,
      { label },
    );
    await this.postgres.query(client, 'SELECT pg_switch_wal()');
    await this.waitUntilShipped(archive, segment, signal);

    return lsn;
  }

  async ship(archive: WalArchive, shipPartial: boolean) {
    await this.serialize(() => this.shipStaged(archive, shipPartial));
  }

  private schedule() {
    if (this.stopped) {
      return;
    }

    const interval =
      this.moduleConfig.get().immichIntegration?.walArchiving?.shipIntervalMs ?? DEFAULT_SHIP_INTERVAL_MS;
    this.timer = setTimeout(() => void this.tick().finally(() => this.schedule()), interval).unref();
  }

  private async getArchive(): Promise<WalArchive | undefined> {
    const config = this.moduleConfig.get().immichIntegration?.walArchiving;
    if (!config) {
      return;
    }

    const integration = await this.repositoryIntegrationImmich.get();
    return integration ? { config, repositoryId: integration.id } : undefined;
  }

  private async getArchiveOrThrow() {
    const archive = await this.getArchive();
    if (!archive) {
      throw new Error('WAL archiving is not configured');
    }

    return archive;
  }

  private getClient(config: ImmichWalArchiving) {
    if (this.client?.config !== config) {
      const client = mkdir(config.stagingPath, { recursive: true }).then(() =>
        this.postgres.createClient(config.binDir, config.connection, join(config.stagingPath, '.pgpass')),
      );
      this.client = { config, client };
    }

    return this.client.client;
  }

  private receiveDirectory(config: ImmichWalArchiving) {
    return join(config.stagingPath, 'receive');
  }

  private async ensureReceiver(archive: WalArchive) {
    if (this.receiver) {
      return;
    }

    this.receiverStarting ??= this.startReceiver(archive).finally(() => (this.receiverStarting = undefined));
    await this.receiverStarting;
  }

  private async startReceiver(archive: WalArchive) {
    const { config } = archive;
    const client = await this.getClient(config);
    const directory = this.receiveDirectory(config);
    await mkdir(directory, { recursive: true });
    await this.ensureSlot(archive, client);

    const receiver = this.postgres.receiveWal(client, directory, config.slotName ?? DEFAULT_SLOT_NAME);
    let stderr = '';
    receiver.stderr?.on('data', (data) => (stderr = (stderr + data).slice(-RECEIVER_STDERR_LIMIT)));

    const onExit = (reason: unknown) => {
      if (this.receiver === receiver) {
        this.receiver = undefined;
      }

      if (!this.stopped) {
        this.logger.warn(`pg_receivewal stopped (${reason}): ${stderr.trim()}`);
      }
    };
    receiver.once('exit', (code, signal) => onExit(code ?? signal));
    receiver.once('error', (error) => onExit(error));

    this.receiver = receiver;
    this.logger.log(`Streaming WAL into ${directory}`);
  }

  private stopReceiver() {
    this.receiver?.kill('SIGTERM');
    this.receiver = undefined;
  }

  private async ensureSlot(archive: WalArchive, client: PostgresClient) {
    const { config } = archive;
    const slot = config.slotName ?? DEFAULT_SLOT_NAME;

    await this.postgres.query(client, `ALTER SYSTEM SET max_slot_wal_keep_size = :'size'`, {
      size: config.maxSlotWalKeepSize ?? DEFAULT_MAX_SLOT_WAL_KEEP_SIZE,
    });
    await this.postgres.query(client, 'SELECT pg_reload_conf()');

    const [existing] = await this.postgres.query(
      client,
      `SELECT wal_status FROM pg_replication_slots WHERE slot_name = :'slot'`,
      { slot },
    );

    if (existing?.[0] === 'lost') {
      this.logger.warn(`Replication slot ${slot} lost WAL past max_slot_wal_keep_size, recreating it`);
      await this.ship(archive, true);
      await this.postgres.query(client, `SELECT pg_drop_replication_slot(:'slot')`, { slot });
      await this.discardStagedWal(config);
    }

    if (!existing || existing[0] === 'lost') {
      await this.postgres.query(client, `SELECT pg_create_physical_replication_slot(:'slot', true)`, { slot });
      this.baseRequired = true;
    }
  }

  private async discardStagedWal(config: ImmichWalArchiving) {
    const directory = this.receiveDirectory(config);
    for (const name of await readdir(directory)) {
      await rm(join(directory, name), { force: true });
    }
  }

  private async listStaged(config: ImmichWalArchiving): Promise<WalFile[]> {
    const directory = this.receiveDirectory(config);
    const names = await readdir(directory).catch(() => []);
    const files = await Promise.all(
      names.map(async (name) => {
        const { size, mtimeMs } = await stat(join(directory, name));
        return { name, size, mtimeMs };
      }),
    );

    return files;
  }

  private stateFile(config: ImmichWalArchiving) {
    return join(config.stagingPath, 'state.json');
  }

  private async readState(config: ImmichWalArchiving): Promise<WalShipState> {
    try {
      return JSON.parse(await readFile(this.stateFile(config), 'utf8')) as WalShipState;
    } catch {
      return { histories: [] };
    }
  }

  private async shipStaged({ config, repositoryId }: WalArchive, shipPartial: boolean) {
    const directory = this.receiveDirectory(config);
    const files = await this.listStaged(config);
    const state = await this.readState(config);
    const { segments, histories, partial } = selectWalFilesToShip(files, state, shipPartial);

    const names = [...histories, ...segments, ...(partial ? [partial.name] : [])];
    if (names.length === 0) {
      return;
    }

    const covered = [...segments, ...(partial ? [partial.name.replace(/\.partial$/, '')] : [])];
    const tags: string[] = [ResticArchiveTag.ImmichWal];
    if (covered.length > 0) {
      tags.push(
        `${ResticTagPrefix.ImmichWalFirstSegment}=${covered[0]}`,
        `${ResticTagPrefix.ImmichWalLastSegment}=${covered.at(-1)}`,
      );
    }

    const { endpoint, key, placement } = await this.repositoryService.getResticParameters(repositoryId);
    await this.restic.backupFiles(
      endpoint,
      key,
      placement,
      names.map((name) => join(directory, name)),
      tags,
    );

    const shipped: WalShipState = {
      lastSegment: segments.at(-1) ?? state.lastSegment,
      histories: [...state.histories, ...histories],
      partial: partial ?? state.partial,
    };
    await writeFile(this.stateFile(config), JSON.stringify(shipped));

    for (const name of selectWalFilesToPrune(
      files.map(({ name }) => name),
      shipped.lastSegment,
    )) {
      await rm(join(directory, name), { force: true });
    }
  }

  private async waitUntilShipped(archive: WalArchive, segment: string, signal?: AbortSignal) {
    const deadline = Date.now() + (archive.config.segmentShippedTimeoutMs ?? DEFAULT_SEGMENT_SHIPPED_TIMEOUT_MS);

    while (true) {
      await this.ship(archive, false);
      const { lastSegment } = await this.readState(archive.config);
      if (lastSegment && lastSegment >= segment) {
        return;
      }

      if (Date.now() > deadline) {
        throw new Error(`WAL segment ${segment} was not archived in time`);
      }

      await sleep(SEGMENT_POLL_INTERVAL_MS, undefined, { signal });
    }
  }

  private async isBaseBackupStale({ config, repositoryId }: WalArchive) {
    const { endpoint, key, placement } = await this.repositoryService.getResticParameters(repositoryId);
    const bases = await this.restic.snapshots(endpoint, key, placement, ResticArchiveTag.ImmichBase);
    const completed = bases.filter(({ tags }) => getTagValue(tags, ResticTagPrefix.ImmichWalBaseStop));
    const newest = Math.max(...completed.map(({ time }) => +time));

    return Date.now() - newest > (config.baseBackupIntervalMs ?? DEFAULT_BASE_BACKUP_INTERVAL_MS);
  }

  private async backupBase({ config, repositoryId }: WalArchive, signal?: AbortSignal): Promise<WalBaseBackup> {
    const client = await this.getClient(config);
    const { endpoint, key, placement } = await this.repositoryService.getResticParameters(repositoryId);

    const [[startLsn]] = await this.postgres.query(client, 'SELECT pg_current_wal_lsn()');
    const summary = await this.restic.backupCommandOutput(
      endpoint,
      key,
      placement,
      BASE_BACKUP_FILENAME,
      this.postgres.baseBackupCommand(client),
      [ResticArchiveTag.ImmichBase, `${ResticTagPrefix.ImmichWalBaseStart}=${startLsn}`],
      signal,
    );
    const [[stopLsn]] = await this.postgres.query(client, 'SELECT pg_current_wal_lsn()');

    const snapshotId = summary.snapshot_id;
    if (!snapshotId) {
      throw new Error('Base backup did not produce a snapshot');
    }

    await this.serialize(() =>
      this.restic.addTags(endpoint, key, placement, snapshotId, [`${ResticTagPrefix.ImmichWalBaseStop}=${stopLsn}`]),
    );
    this.baseRequired = false;

    return { startLsn, stopLsn };
  }

  private serialize<T>(task: () => Promise<T>): Promise<T> {
    const run = this.serial.then(task, task);
    this.serial = run.catch(() => {});
    return run;
  }
}
