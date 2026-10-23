import { JobName } from '../enum.js';
import type { JobContext } from '../jobs/jobContext.js';
import type { RepositoryBackupJob } from '../jobs/repositoryBackup.job.js';
import type { RepositoryPruneJob } from '../jobs/repositoryPrune.job.js';
import type { RepositoryRestoreJob } from '../jobs/repositoryRestore.job.js';
import type { RepositoryRestoreFromPointJob } from '../jobs/repositoryRestoreFromPoint.job.js';
import type { RepositorySnapshotForgetJob } from '../jobs/repositorySnapshotForget.job.js';
import type { RepositorySyncMetricsJob } from '../jobs/repositorySyncMetrics.job.js';

export type CircularDependency<T> = T;

export type JobHandler<T> = {
  run(data: T, ctx: JobContext): Promise<void>;
};

type Jobs = {
  [JobName.RepositoryBackup]: RepositoryBackupJob;
  [JobName.RepositoryPrune]: RepositoryPruneJob;
  [JobName.RepositoryRestore]: RepositoryRestoreJob;
  [JobName.RepositoryRestoreFromPoint]: RepositoryRestoreFromPointJob;
  [JobName.RepositorySnapshotForget]: RepositorySnapshotForgetJob;
  [JobName.RepositorySyncMetrics]: RepositorySyncMetricsJob;
};

export type JobItem = {
  [Name in JobName]: { name: Name; data: Parameters<Jobs[Name]['run']>[0] };
}[JobName];
