import { jest } from '@jest/globals';
import { EventEmitter } from 'node:events';
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { newResticRepositoryMock } from '../../test/mocks.js';
import { ResticArchiveTag, ResticTagPrefix } from '../enum.js';
import type { ImmichWalArchiving } from '../moduleConfig.js';
import { LoggingRepository } from '../repositories/logging.repository.js';
import { ImmichWalService } from './immichWal.service.js';

const SEGMENT_1 = '000000010000000000000001';
const SEGMENT_2 = '000000010000000000000002';
const SEGMENT_3 = '000000010000000000000003';

describe(ImmichWalService.name, () => {
  let stagingPath: string;
  let receiveDirectory: string;

  const resticParameters = {
    endpoint: 'rest:https://example.com/repository',
    key: new Uint8Array([1]),
    placement: { siteCode: null, storageClusterCode: null },
  };

  const stage = async (...names: string[]) => {
    for (const name of names) {
      await writeFile(join(receiveDirectory, name), name);
    }
  };

  const makeService = (slotStatus?: string, createClient = jest.fn<() => Promise<object>>().mockResolvedValue({})) => {
    const walArchiving: ImmichWalArchiving = {
      binDir: '/usr/lib/postgresql/14/bin',
      stagingPath,
      connection: { host: 'database', port: 5432, user: 'postgres', password: 'secret', database: 'immich' },
      segmentShippedTimeoutMs: 2000,
    };
    const moduleConfig = {
      get: () => ({ immichIntegration: { walArchiving } }),
      hasLock: () => true,
    };
    const repositoryIntegrationImmich = { get: jest.fn<() => Promise<object>>().mockResolvedValue({ id: 'immich' }) };
    const repositoryService = {
      getResticParameters: jest.fn<() => Promise<typeof resticParameters>>().mockResolvedValue(resticParameters),
    };
    const restic = newResticRepositoryMock();
    const receiver = Object.assign(new EventEmitter(), { stderr: new EventEmitter(), kill: jest.fn() });
    const postgres = {
      createClient,
      receiveWal: jest.fn().mockReturnValue(receiver),
      baseBackupCommand: jest.fn().mockReturnValue(['pg_basebackup']),
      query: jest.fn(async (_client: unknown, sql: string): Promise<string[][]> => {
        if (sql.includes('wal_segment_size')) {
          return [['16MB']];
        }
        if (sql.includes('pg_replication_slots')) {
          return slotStatus ? [[slotStatus]] : [];
        }
        if (sql.includes('pg_current_wal_lsn')) {
          return [['0/1000028', SEGMENT_1]];
        }
        if (sql.includes('pg_create_restore_point')) {
          await stage(SEGMENT_2);
          return [['0/2000090', SEGMENT_2]];
        }
        return [];
      }),
    };

    const service = new ImmichWalService(
      moduleConfig as never,
      repositoryIntegrationImmich as never,
      repositoryService as never,
      restic as never,
      postgres as never,
      LoggingRepository.create(),
    );

    return { service, restic, postgres };
  };

  beforeEach(async () => {
    stagingPath = await mkdtemp(join(tmpdir(), 'immich-wal-'));
    receiveDirectory = join(stagingPath, 'receive');
    await mkdir(receiveDirectory, { recursive: true });
  });

  afterEach(async () => {
    await rm(stagingPath, { recursive: true, force: true });
  });

  it('creates the slot with its WAL cap before streaming', async () => {
    const { service, postgres } = makeService();

    await service.tick();

    const statements = postgres.query.mock.calls.map(([, sql]) => sql);
    expect(statements).toContain(`ALTER SYSTEM SET max_slot_wal_keep_size = :'size'`);
    expect(statements).toContain(`SELECT pg_create_physical_replication_slot(:'slot', true)`);
    expect(postgres.receiveWal).toHaveBeenCalledWith(expect.anything(), receiveDirectory, 'futo_backups');
  });

  it('recreates a slot that lost WAL and requires a new base backup', async () => {
    const { service, postgres, restic } = makeService('lost');
    restic.backupCommandOutput.mockResolvedValue({ snapshot_id: 'base-1' } as never);
    await stage(`${SEGMENT_1}.partial`);

    const base = await service.backupBaseIfDue();

    const statements = postgres.query.mock.calls.map(([, sql]) => sql);
    expect(statements).toContain(`SELECT pg_drop_replication_slot(:'slot')`);
    expect(await readdir(receiveDirectory)).toEqual([]);
    expect(base).toBeDefined();
    expect(restic.addTags).toHaveBeenCalledWith(
      resticParameters.endpoint,
      resticParameters.key,
      resticParameters.placement,
      'base-1',
      [expect.stringMatching(`^${ResticTagPrefix.ImmichWalBaseStop}=`)],
    );
  });

  it('ships completed segments, then prunes all but the newest of them', async () => {
    const { service, restic } = makeService('reserved');
    await stage(SEGMENT_1, SEGMENT_2, `${SEGMENT_3}.partial`, '00000001.history');

    await service.tick();

    expect(restic.backupFiles).toHaveBeenCalledWith(
      resticParameters.endpoint,
      resticParameters.key,
      resticParameters.placement,
      [
        join(receiveDirectory, '00000001.history'),
        join(receiveDirectory, SEGMENT_1),
        join(receiveDirectory, SEGMENT_2),
        join(receiveDirectory, `${SEGMENT_3}.partial`),
      ],
      [
        ResticArchiveTag.ImmichWal,
        `${ResticTagPrefix.ImmichWalFirstSegment}=${SEGMENT_1}`,
        `${ResticTagPrefix.ImmichWalLastSegment}=${SEGMENT_2}`,
        `${ResticTagPrefix.ImmichWalPartialSegment}=${SEGMENT_3}`,
      ],
    );
    const staged = await readdir(receiveDirectory);
    expect(staged.toSorted()).toEqual(['00000001.history', SEGMENT_2, `${SEGMENT_3}.partial`]);

    await service.tick();

    expect(restic.backupFiles).toHaveBeenCalledTimes(1);
  });

  it('keeps the staged WAL when restic fails so the next tick retries it', async () => {
    const { service, restic } = makeService('reserved');
    restic.backupFiles.mockRejectedValueOnce(new Error('repository is already locked exclusively'));
    await stage(SEGMENT_1, SEGMENT_2);

    await service.tick();
    const staged = await readdir(receiveDirectory);
    expect(staged.toSorted()).toEqual([SEGMENT_1, SEGMENT_2]);

    await service.tick();
    expect(restic.backupFiles).toHaveBeenCalledTimes(2);
    expect(await readdir(receiveDirectory)).toEqual([SEGMENT_2]);
  });

  it('returns the restore point LSN once its segment is in the repository', async () => {
    const { service, restic, postgres } = makeService('reserved');
    await stage(SEGMENT_1);

    const lsn = await service.prepareSnapshot('futo-backups-1');

    expect(lsn).toBe('0/2000090');
    expect(postgres.query).toHaveBeenCalledWith(expect.anything(), 'SELECT pg_switch_wal()', {}, undefined);
    expect(restic.backupFiles.mock.calls.at(-1)?.[3]).toContain(join(receiveDirectory, SEGMENT_2));
  });

  it('keeps the passfile outside staging and marks staging as a cache directory', async () => {
    const { service, postgres } = makeService('reserved');

    await service.tick();

    const passfile = postgres.createClient.mock.calls[0] as unknown[];
    expect(passfile[2]).not.toContain(stagingPath);
    expect(await readFile(join(stagingPath, 'CACHEDIR.TAG'), 'utf8')).toMatch(
      /^Signature: 8a477f597d28d172789f06886806bc55/,
    );
    await service.onApplicationShutdown();
  });

  it('retries client initialisation after it failed', async () => {
    const createClient = jest
      .fn<() => Promise<object>>()
      .mockRejectedValueOnce(new Error('disk full'))
      .mockResolvedValue({});
    const { service, postgres } = makeService('reserved', createClient);

    await service.tick();
    expect(postgres.receiveWal).not.toHaveBeenCalled();

    await service.tick();
    expect(createClient).toHaveBeenCalledTimes(2);
    expect(postgres.receiveWal).toHaveBeenCalledTimes(1);
  });

  it('does not start the receiver when shut down while the slot is being prepared', async () => {
    const { service, postgres } = makeService('reserved');
    const slotQuery = Promise.withResolvers<string[][]>();
    const slotQueried = Promise.withResolvers<void>();
    const query = postgres.query.getMockImplementation()!;
    postgres.query.mockImplementation((client, sql, ...rest) => {
      if (!sql.includes('pg_replication_slots')) {
        return query(client, sql, ...rest);
      }
      slotQueried.resolve();
      return slotQuery.promise;
    });

    const tick = service.tick();
    await slotQueried.promise;
    await service.onApplicationShutdown();
    slotQuery.resolve([['reserved']]);
    await tick;

    expect(postgres.receiveWal).not.toHaveBeenCalled();
  });

  it('still requires a new base backup after a restart that followed slot recreation', async () => {
    const { service: before } = makeService('lost');
    await before.tick();

    const { service: after, restic } = makeService('reserved');
    restic.snapshots.mockResolvedValue([
      { time: new Date(), tags: [ResticArchiveTag.ImmichBase, `${ResticTagPrefix.ImmichWalBaseStop}=0/1`] },
    ] as never);
    restic.backupCommandOutput.mockResolvedValue({ snapshot_id: 'base-2' } as never);

    expect(await after.backupBaseIfDue()).toBeDefined();
    expect(await after.backupBaseIfDue()).toBeUndefined();
  });

  it('ships each contiguous run of segments as its own snapshot', async () => {
    const { service, restic } = makeService('reserved');
    await stage(SEGMENT_1, SEGMENT_3);

    await service.tick();

    expect(restic.backupFiles.mock.calls.map((call) => call[4])).toEqual([
      [
        ResticArchiveTag.ImmichWal,
        `${ResticTagPrefix.ImmichWalFirstSegment}=${SEGMENT_1}`,
        `${ResticTagPrefix.ImmichWalLastSegment}=${SEGMENT_1}`,
      ],
      [
        ResticArchiveTag.ImmichWal,
        `${ResticTagPrefix.ImmichWalFirstSegment}=${SEGMENT_3}`,
        `${ResticTagPrefix.ImmichWalLastSegment}=${SEGMENT_3}`,
      ],
    ]);
  });
});
