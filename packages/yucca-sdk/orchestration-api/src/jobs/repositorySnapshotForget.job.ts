import { Job } from '../decorators.js';
import { JobName } from '../enum.js';
import { JobRepository } from '../repositories/job.repository.js';
import { ResticRepository } from '../repositories/restic.repository.js';
import { RepositoryService } from '../services/repository.service.js';
import { TelemetryService } from '../services/telemetry.service.js';
import type { JobHandler } from '../utils/types.js';
import { JobContext } from './jobContext.js';

type RepositorySnapshotForgetData = {
  repositoryId: string;
  snapshotId: string;
};

@Job({ name: JobName.RepositorySnapshotForget })
export class RepositorySnapshotForgetJob implements JobHandler<RepositorySnapshotForgetData> {
  constructor(
    private readonly repositoryService: RepositoryService,
    private readonly restic: ResticRepository,
    private readonly jobs: JobRepository,
    private readonly telemetry: TelemetryService,
  ) {}

  async run({ repositoryId, snapshotId }: RepositorySnapshotForgetData, ctx: JobContext): Promise<void> {
    this.telemetry.submitStructuredLog('Running repository snapshot forget', {
      repositoryId,
      snapshotId,
    });

    const { endpoint, key, placement } = await this.repositoryService.getResticParameters(repositoryId);

    let error;
    try {
      await this.restic.unlockAll(endpoint, key, placement);
      await this.restic.forget(endpoint, key, placement, snapshotId, true, ctx.signal);
    } catch (error_) {
      error = error_;
    }

    this.telemetry.submitStructuredLog('Finished repository snapshot forget', {
      repositoryId,
      snapshotId,
      error,
    });

    if (error) {
      throw error;
    }

    await this.jobs.queue({ name: JobName.RepositorySyncMetrics, data: { repositoryId } });
  }
}
