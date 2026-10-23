import { Job } from '../decorators.js';
import { RepositorySnapshotRestoreRequestDto } from '../dto/repository.dto.js';
import { JobName } from '../enum.js';
import { ResticRepository } from '../repositories/restic.repository.js';
import { RepositoryService } from '../services/repository.service.js';
import { TelemetryService } from '../services/telemetry.service.js';
import type { JobHandler } from '../utils/types.js';
import { JobContext } from './jobContext.js';

type RepositoryRestoreData = {
  repositoryId: string;
  snapshotId: string;
  options: RepositorySnapshotRestoreRequestDto;
};

@Job({ name: JobName.RepositoryRestore })
export class RepositoryRestoreJob implements JobHandler<RepositoryRestoreData> {
  constructor(
    private readonly repositoryService: RepositoryService,
    private readonly restic: ResticRepository,
    private readonly telemetry: TelemetryService,
  ) {}

  async run({ repositoryId, snapshotId, options }: RepositoryRestoreData, ctx: JobContext): Promise<void> {
    this.telemetry.submitStructuredLog('Running repository snapshot restore', {
      repositoryId,
      snapshotId,
    });

    const { endpoint, key, placement } = await this.repositoryService.getResticParameters(repositoryId);

    let summary;
    let error;
    try {
      summary = await this.restic.restore(
        endpoint,
        key,
        placement,
        snapshotId,
        options,
        (event) => ctx.log(event),
        ctx.signal,
      );
    } catch (error_) {
      error = error_;
    }

    this.telemetry.submitStructuredLog('Finished repository snapshot restore', {
      repositoryId,
      snapshotId,
      summary,
      error,
    });

    if (error) {
      throw error;
    }
  }
}
