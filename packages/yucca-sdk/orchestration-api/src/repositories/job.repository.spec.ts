import { Reflector } from '@nestjs/core';
import { Job } from '../decorators.js';
import { JobName } from '../enum.js';
import { JobRepository } from './job.repository.js';

@Job({ name: JobName.RepositorySnapshotForget })
class SnapshotForgetJob {
  async run() {}
}

@Job({ name: JobName.RepositorySnapshotForget })
class OtherSnapshotForgetJob {
  async run() {}
}

@Job({ name: JobName.RepositorySyncMetrics })
class SyncMetricsJob {
  async run() {}
}

@Job({ name: JobName.RepositoryPrune })
class PruneJob {
  async run() {}
}

@Job({ name: JobName.RepositoryBackup })
class BackupJob {
  async run() {}
}

@Job({ name: JobName.RepositoryRestore })
class RestoreJob {
  async run() {}
}

@Job({ name: JobName.RepositoryRestoreFromPoint })
class RestoreFromPointJob {
  async run() {}
}

class PlainService {}

const makeRepository = (metatypes: Array<new () => object>) => {
  const discovery = {
    getProviders: () => metatypes.map((metatype) => ({ metatype, instance: new metatype() })),
  };

  const logger = { setContext: () => {} };

  return new JobRepository(
    {} as never,
    discovery as never,
    new Reflector(),
    {} as never,
    {} as never,
    {} as never,
    logger as never,
  );
};

describe(JobRepository.name, () => {
  it('registers a handler for every job name', () => {
    const repository = makeRepository([
      SnapshotForgetJob,
      SyncMetricsJob,
      PruneJob,
      BackupJob,
      RestoreJob,
      RestoreFromPointJob,
      PlainService,
    ]);

    expect(() => repository.onModuleInit()).not.toThrow();
  });

  it('fails when a job name has no handler', () => {
    const repository = makeRepository([
      SyncMetricsJob,
      PruneJob,
      BackupJob,
      RestoreJob,
      RestoreFromPointJob,
      PlainService,
    ]);

    expect(() => repository.onModuleInit()).toThrow('Failed to find job handler for repository-snapshot-forget');
  });

  it('fails when two handlers claim the same job name', () => {
    const repository = makeRepository([
      SnapshotForgetJob,
      OtherSnapshotForgetJob,
      SyncMetricsJob,
      PruneJob,
      BackupJob,
      RestoreJob,
      RestoreFromPointJob,
    ]);

    expect(() => repository.onModuleInit()).toThrow(
      'Failed to add job handler for OtherSnapshotForgetJob, repository-snapshot-forget is already handled by SnapshotForgetJob',
    );
  });
});
