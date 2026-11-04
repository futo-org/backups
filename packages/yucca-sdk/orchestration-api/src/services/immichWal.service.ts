import { Injectable, OnApplicationBootstrap, OnApplicationShutdown } from '@nestjs/common';
import type { ChildProcess } from 'node:child_process';
import { mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
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
  nextSegment,
  selectWalFilesToPrune,
  selectWalFilesToShip,
  splitContiguousSegments,
  SUPPORTED_WAL_SEGMENT_SIZE,
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
const CACHEDIR_TAG =
  'Signature: 8a477f597d28d172789f06886806bc55\n# Excludes FUTO Backups WAL staging from library backups.\n';

type WalArchive = { config: ImmichWalArchiving; repositoryId: string };

type WalShipment = { segments: string[]; histories: string[]; partial?: WalFile };

export type WalBaseBackup = { startLsn: string; stopLsn: string };

@Injectable()
export class ImmichWalService implements OnApplicationBootstrap, OnApplicationShutdown {
  private receiver?: ChildProcess;
  private receiverStarting?: Promise<void>;
  private timer?: NodeJS.Timeout;
  private stopped = false;
  private serial: Promise<unknown> = Promise.resolve();
  private client?: { config: ImmichWalArchiving; client: Promise<PostgresClient>; passfileDirectory: Promise<string> };

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

    await this.removePassfile(this.client);
  }

  private async removePassfile(client = this.client) {
    const passfileDirectory = await client?.passfileDirectory.catch(() => '');
    if (passfileDirectory) {
      await rm(passfileDirectory, { recursive: true, force: true });
    }
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
    await this.ensureReceiver(archive, signal);

    const { baseRequiredSince } = await this.readState(archive.config);
    if (!force && baseRequiredSince === undefined && !(await this.isBaseBackupStale(archive))) {
      return;
    }

    return await this.backupBase(archive, signal);
  }

  async prepareSnapshot(label: string, signal?: AbortSignal): Promise<string> {
    const archive = await this.getArchiveOrThrow();
    await this.ensureReceiver(archive, signal);

    const client = await this.getClient(archive.config);
    const [[lsn, segment]] = await this.postgres.query(
      client,
      `SELECT lsn, pg_walfile_name(lsn) FROM pg_create_restore_point(:'label') AS lsn`,
      { label },
      signal,
    );
    await this.postgres.query(client, 'SELECT pg_switch_wal()', {}, signal);
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
      void this.removePassfile(this.client);
      const passfileDirectory = mkdtemp(join(tmpdir(), 'futo-backups-wal-'));
      const client = this.prepareStaging(config)
        .then(() => passfileDirectory)
        .then((directory) => this.postgres.createClient(config.binDir, config.connection, join(directory, '.pgpass')));
      const entry = { config, client, passfileDirectory };
      client.catch(() => {
        if (this.client === entry) {
          this.client = undefined;
        }
      });
      this.client = entry;
    }

    return this.client.client;
  }

  private async prepareStaging(config: ImmichWalArchiving) {
    await mkdir(config.stagingPath, { recursive: true });
    await writeFile(join(config.stagingPath, 'CACHEDIR.TAG'), CACHEDIR_TAG);
  }

  private receiveDirectory(config: ImmichWalArchiving) {
    return join(config.stagingPath, 'receive');
  }

  private async ensureReceiver(archive: WalArchive, signal?: AbortSignal) {
    if (this.receiver || this.stopped) {
      return;
    }

    this.receiverStarting ??= this.startReceiver(archive, signal).finally(() => (this.receiverStarting = undefined));
    await this.receiverStarting;
  }

  private async startReceiver(archive: WalArchive, signal?: AbortSignal) {
    const { config } = archive;
    const client = await this.getClient(config);
    const directory = this.receiveDirectory(config);
    await mkdir(directory, { recursive: true });
    await this.ensureSlot(archive, client, signal);
    if (this.stopped) {
      return;
    }

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

  private async ensureSlot(archive: WalArchive, client: PostgresClient, signal?: AbortSignal) {
    const { config } = archive;
    const slot = config.slotName ?? DEFAULT_SLOT_NAME;
    const query = (sql: string, variables: Record<string, string> = {}) =>
      this.postgres.query(client, sql, variables, signal);

    const [[segmentSize]] = await query(`SELECT current_setting('wal_segment_size')`);
    if (segmentSize !== SUPPORTED_WAL_SEGMENT_SIZE) {
      throw new Error(`Unsupported wal_segment_size ${segmentSize}, expected ${SUPPORTED_WAL_SEGMENT_SIZE}`);
    }

    await query(`ALTER SYSTEM SET max_slot_wal_keep_size = :'size'`, {
      size: config.maxSlotWalKeepSize ?? DEFAULT_MAX_SLOT_WAL_KEEP_SIZE,
    });
    await query('SELECT pg_reload_conf()');

    const [existing] = await query(`SELECT wal_status FROM pg_replication_slots WHERE slot_name = :'slot'`, { slot });
    if (existing && existing[0] !== 'lost') {
      return;
    }

    await this.updateState(config, { baseRequiredSince: Date.now() });

    if (existing) {
      this.logger.warn(`Replication slot ${slot} lost WAL past max_slot_wal_keep_size, recreating it`);
      await this.ship(archive, true);
      await query(`SELECT pg_drop_replication_slot(:'slot')`, { slot });
      await this.discardStagedWal(config);
    }

    await query(`SELECT pg_create_physical_replication_slot(:'slot', true)`, { slot });
  }

  private updateState(config: ImmichWalArchiving, changes: Partial<WalShipState>) {
    return this.serialize(async () => this.writeState(config, { ...(await this.readState(config)), ...changes }));
  }

  private async writeState(config: ImmichWalArchiving, state: WalShipState) {
    await writeFile(this.stateFile(config), JSON.stringify(state));
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

    const shipments = this.planShipments(segments, histories, partial);
    if (shipments.length === 0) {
      return;
    }

    const { endpoint, key, placement } = await this.repositoryService.getResticParameters(repositoryId);
    for (const shipment of shipments) {
      const names = [...shipment.histories, ...shipment.segments, ...(shipment.partial ? [shipment.partial.name] : [])];
      await this.restic.backupFiles(
        endpoint,
        key,
        placement,
        names.map((name) => join(directory, name)),
        this.shipmentTags(shipment),
      );
    }

    const shipped: WalShipState = {
      ...state,
      lastSegment: segments.at(-1) ?? state.lastSegment,
      histories: [...state.histories, ...histories],
      partial: partial ?? state.partial,
    };
    await this.writeState(config, shipped);

    for (const name of selectWalFilesToPrune(
      files.map(({ name }) => name),
      shipped.lastSegment,
    )) {
      await rm(join(directory, name), { force: true });
    }
  }

  private planShipments(segments: string[], histories: string[], partial?: WalFile): WalShipment[] {
    const shipments: WalShipment[] = splitContiguousSegments(segments).map((run) => ({ segments: run, histories: [] }));
    const partialSegment = partial?.name.replace(/\.partial$/, '');
    const last = shipments.at(-1);

    if (partial && last && nextSegment(last.segments.at(-1)!) === partialSegment) {
      last.partial = partial;
    } else if (partial) {
      shipments.push({ segments: [], histories: [], partial });
    }

    if (histories.length > 0) {
      if (shipments.length === 0) {
        shipments.push({ segments: [], histories: [] });
      }
      shipments[0].histories = histories;
    }

    return shipments;
  }

  private shipmentTags({ segments, partial }: WalShipment) {
    const tags: string[] = [ResticArchiveTag.ImmichWal];
    if (segments.length > 0) {
      tags.push(
        `${ResticTagPrefix.ImmichWalFirstSegment}=${segments[0]}`,
        `${ResticTagPrefix.ImmichWalLastSegment}=${segments.at(-1)}`,
      );
    }
    if (partial) {
      tags.push(`${ResticTagPrefix.ImmichWalPartialSegment}=${partial.name.replace(/\.partial$/, '')}`);
    }

    return tags;
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

    const startedAt = Date.now();
    const [[startLsn, startSegment]] = await this.postgres.query(
      client,
      'SELECT lsn, pg_walfile_name(lsn) FROM pg_current_wal_lsn() AS lsn',
      {},
      signal,
    );
    const summary = await this.restic.backupCommandOutput(
      endpoint,
      key,
      placement,
      BASE_BACKUP_FILENAME,
      this.postgres.baseBackupCommand(client),
      [
        ResticArchiveTag.ImmichBase,
        `${ResticTagPrefix.ImmichWalBaseStart}=${startLsn}`,
        `${ResticTagPrefix.ImmichWalBaseStartSegment}=${startSegment}`,
      ],
      signal,
    );
    const [[stopLsn]] = await this.postgres.query(client, 'SELECT pg_current_wal_lsn()', {}, signal);

    const snapshotId = summary.snapshot_id;
    if (!snapshotId) {
      throw new Error('Base backup did not produce a snapshot');
    }

    await this.serialize(async () => {
      await this.restic.addTags(endpoint, key, placement, snapshotId, [
        `${ResticTagPrefix.ImmichWalBaseStop}=${stopLsn}`,
      ]);
      const state = await this.readState(config);
      if (state.baseRequiredSince !== undefined && state.baseRequiredSince <= startedAt) {
        await this.writeState(config, { ...state, baseRequiredSince: undefined });
      }
    });

    return { startLsn, stopLsn };
  }

  private serialize<T>(task: () => Promise<T>): Promise<T> {
    const run = this.serial.then(task, task);
    this.serial = run.catch(() => {});
    return run;
  }
}
