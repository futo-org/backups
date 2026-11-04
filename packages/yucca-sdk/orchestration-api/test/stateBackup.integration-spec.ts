import { jest } from '@jest/globals';
import { mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { ConfigurationKey, JobStatus } from '../src/enum.js';
import type { DatabaseHooks } from '../src/moduleConfig.js';
import { JobRepository } from '../src/repositories/job.repository.js';
import { ModuleConfigRepository } from '../src/repositories/moduleConfig.repository.js';
import { RepositoryService } from '../src/services/repository.service.js';
import { YuccaService } from '../src/services/yucca.service.js';
import { createTestingModule, TestContext } from './testUtils.js';

let ctx: TestContext;

const getConfig = (key: ConfigurationKey) =>
  ctx.db.selectFrom('futo_backups_config').select('value').where('key', '=', key).executeTakeFirst();

const tagName = 'yucca.v1.stateDumpFileName';
const dumpTag = `${tagName}=state.dump`;

const useDatabaseHooks = (databaseHooks?: DatabaseHooks) =>
  ctx.module.get(ModuleConfigRepository).update({ databaseHooks });

const restorePoint = async (tags: string[], yuccaConfig?: string) => {
  ctx.resticMock.snapshot.mockResolvedValue([{ id: 'snapshot-1', time: new Date(), tags }] as never);
  ctx.resticMock.restore.mockImplementation((async (...args: unknown[]) => {
    const { target } = args[4] as { target?: string };
    if (target) {
      await mkdir(join(target, 'state'), { recursive: true });
    }
  }) as never);

  const { jobId } = await ctx.module
    .get(RepositoryService)
    .restoreFromPoint('remote-repository', 'snapshot-1', ctx.backendId, { include: ['/photos'], yuccaConfig });

  return ctx.module.get(JobRepository).wait(jobId);
};

beforeAll(async () => {
  ctx = await createTestingModule();
}, 15_000);

afterAll(async () => {
  await ctx.app.close();
});

afterEach(() => {
  ctx.resticMock.restore.mockReset();
  ctx.resticMock.backup.mockReset();
  ctx.resticMock.snapshot.mockResolvedValue([] as never);
  useDatabaseHooks();
});

const backUp = async (paths: string[]) => {
  const service = ctx.module.get(RepositoryService);
  const { repository } = await service.createRepository({ name: 'State', worm: false, paths }, ctx.backendId);
  const { jobId } = await service.createBackup(repository.id);
  await ctx.module.get(JobRepository).wait(jobId);
};

const backupTags = () => ctx.resticMock.backup.mock.calls[0][6];

describe('backup of the state directory', () => {
  it('tags the backup with the database dump the host wrote', async () => {
    useDatabaseHooks({ tagName, dump: () => Promise.resolve('state.dump'), restore: () => Promise.resolve() });

    await backUp([ctx.statePath]);

    expect(backupTags()).toEqual([dumpTag]);
  });

  it('leaves out the database dump when the state directory is not backed up', async () => {
    const dump = jest.fn(() => Promise.resolve('state.dump'));
    useDatabaseHooks({ tagName, dump, restore: () => Promise.resolve() });

    await backUp(['/photos']);

    expect(dump).not.toHaveBeenCalled();
    expect(backupTags()).toEqual([]);
  });

  it('tags the backup with the database dump when a parent of the state directory is backed up', async () => {
    useDatabaseHooks({ tagName, dump: () => Promise.resolve('state.dump'), restore: () => Promise.resolve() });

    await backUp([dirname(ctx.statePath)]);

    expect(backupTags()).toEqual([dumpTag]);
  });
});

describe('restore from point', () => {
  it('hands the database dump tagged on the snapshot to the host', async () => {
    const restore = jest.fn(() => Promise.resolve());
    useDatabaseHooks({ tagName, dump: () => Promise.resolve('state.dump'), restore });

    await expect(restorePoint([dumpTag], 'state')).resolves.toMatchObject({ status: JobStatus.Complete });

    expect(restore).toHaveBeenCalledWith('state.dump');
  });

  it('leaves the current state alone when the configuration is not selected for restore', async () => {
    const restore = jest.fn(() => Promise.resolve());
    useDatabaseHooks({ tagName, dump: () => Promise.resolve('state.dump'), restore });

    await expect(restorePoint([dumpTag])).resolves.toMatchObject({ status: JobStatus.Complete });

    expect(restore).not.toHaveBeenCalled();
  });

  it('boots again against the database the host restored', async () => {
    useDatabaseHooks({
      tagName,
      dump: () => Promise.resolve('state.dump'),
      restore: async () => {
        await ctx.db.deleteFrom('futo_backups_config').where('key', '=', ConfigurationKey.StatePath).execute();
      },
    });

    await expect(restorePoint([dumpTag], 'state')).resolves.toMatchObject({ status: JobStatus.Complete });

    await expect(getConfig(ConfigurationKey.StatePath)).resolves.toEqual({ value: { path: ctx.statePath } });
  });

  it('leaves the current state alone when the host has no database hooks', async () => {
    const before = await ctx.db.selectFrom('futo_backups_config').selectAll().orderBy('key').execute();

    await expect(restorePoint([dumpTag], 'state')).resolves.toMatchObject({ status: JobStatus.Complete });

    await expect(ctx.db.selectFrom('futo_backups_config').selectAll().orderBy('key').execute()).resolves.toEqual(
      before,
    );
  });

  it('fails without touching the current state when restoring the state files fails', async () => {
    const before = await getConfig(ConfigurationKey.EncryptionKey);
    ctx.resticMock.restore.mockImplementation(((...args: unknown[]) => {
      const { target } = args[4] as { target?: string };
      return target ? Promise.reject(new Error('restic restore failed')) : Promise.resolve();
    }) as never);

    const { jobId } = await ctx.module
      .get(RepositoryService)
      .restoreFromPoint('remote-repository', 'snapshot-1', ctx.backendId, { yuccaConfig: 'state' });

    await expect(ctx.module.get(JobRepository).wait(jobId)).rejects.toThrow('restic restore failed');
    await expect(getConfig(ConfigurationKey.EncryptionKey)).resolves.toEqual(before);
  });
});

describe('in-place restore', () => {
  it('finds no database dump when the host has no database hooks', async () => {
    const service = ctx.module.get(RepositoryService);
    const { repository } = await service.createRepository(
      { name: 'In place', worm: false, paths: ['/photos'] },
      ctx.backendId,
    );
    ctx.resticMock.snapshot.mockResolvedValue([{ id: 'snapshot-1', time: new Date(), tags: [dumpTag] }] as never);

    const { task, immichBackupFileName } = await ctx.module
      .get(YuccaService)
      .restoreSnapshotInplace(repository.id, 'snapshot-1');
    await task;

    expect(immichBackupFileName).toBeUndefined();
  });
});
