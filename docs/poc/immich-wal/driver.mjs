import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';

const dist = resolve(import.meta.dirname, '../../../packages/yucca-sdk/orchestration-api/dist');
const load = (path) => import(join(dist, path));

const { ImmichWalService } = await load('services/immichWal.service.js');
const { ResticRepository } = await load('repositories/restic.repository.js');
const { PostgresRepository } = await load('repositories/postgres.repository.js');
const { LoggingRepository } = await load('repositories/logging.repository.js');
const { ResticTagPrefix } = await load('enum.js');

const env = (name, fallback) => {
  const value = process.env[name] ?? fallback;
  if (value === undefined) {
    throw new Error(`${name} is required`);
  }
  return value;
};

const workDir = env('WAL_E2E_DIR');
const resticParameters = {
  endpoint: env('RESTIC_REPOSITORY'),
  key: Buffer.from(env('RESTIC_KEY_HEX'), 'hex'),
  placement: { siteCode: null, storageClusterCode: null },
};

const walArchiving = {
  binDir: env('PG_BIN_DIR'),
  stagingPath: join(workDir, 'staging'),
  connection: {
    host: '127.0.0.1',
    port: Number(env('PG_PORT')),
    user: 'postgres',
    password: env('PG_PASSWORD'),
    database: 'immich',
  },
  maxSlotWalKeepSize: env('MAX_SLOT_WAL_KEEP_SIZE', '64MB'),
  shipIntervalMs: Number(env('SHIP_INTERVAL_MS', '5000')),
  shipPartial: true,
};

const moduleConfig = {
  get: () => ({ cachePath: join(workDir, 'restic-cache'), immichIntegration: { walArchiving } }),
  hasLock: () => true,
};
const restic = new ResticRepository(
  { getResticOptions: () => Promise.resolve({ connections: 4, packSizeMib: 16 }) },
  moduleConfig,
  { current: () => undefined },
);
const service = new ImmichWalService(
  moduleConfig,
  { get: () => Promise.resolve({ id: 'immich' }) },
  { getResticParameters: () => Promise.resolve(resticParameters) },
  restic,
  new PostgresRepository(),
  LoggingRepository.create('e2e'),
);

const snapshotLibrary = async () => {
  const lsn = await service.prepareSnapshot(`futo-backups-e2e-${Date.now()}`);
  const { endpoint, key, placement } = resticParameters;
  const paths = [env('LIBRARY_DIR'), walArchiving.stagingPath];
  const summary = await restic.backup(endpoint, key, placement, paths, undefined, undefined, [
    `${ResticTagPrefix.ImmichWalLsn}=${lsn}`,
  ]);
  return { lsn, snapshotId: summary.snapshot_id };
};

const commands = {
  tick: async () => {
    await service.tick();
    return {};
  },
  base: async () => (await service.backupBaseIfDue(undefined, true)) ?? {},
  'base-if-due': async () => ({ base: (await service.backupBaseIfDue()) ?? null }),
  snapshot: snapshotLibrary,
  stop: async () => {
    await service.onApplicationShutdown();
    return {};
  },
};

const reply = (result) => process.stdout.write(`@@ ${JSON.stringify(result)}\n`);

service.onApplicationBootstrap();

for await (const line of createInterface({ input: process.stdin })) {
  const command = commands[line.trim()];
  if (!command) {
    reply({ error: `unknown command: ${line}` });
    continue;
  }

  try {
    reply(await command());
  } catch (error) {
    reply({ error: String(error?.stack ?? error) });
  }

  if (line.trim() === 'stop') {
    break;
  }
}

process.exit(0);
