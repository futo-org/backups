import { NotFoundException } from '@nestjs/common';
import { Job } from '../decorators.js';
import { JobName } from '../enum.js';
import { JobRepository } from '../repositories/job.repository.js';
import { RepositoryRepository } from '../repositories/repository.repository.js';
import { ResticRepository } from '../repositories/restic.repository.js';
import { RepositoryService } from '../services/repository.service.js';
import { TelemetryService } from '../services/telemetry.service.js';
import type { JobHandler } from '../utils/types.js';
import { JobContext } from './jobContext.js';

type RepositoryPruneData = {
  repositoryId: string;
};

@Job({ name: JobName.RepositoryPrune })
export class RepositoryPruneJob implements JobHandler<RepositoryPruneData> {
  constructor(
    private readonly repositoryService: RepositoryService,
    private readonly repository: RepositoryRepository,
    private readonly restic: ResticRepository,
    private readonly jobs: JobRepository,
    private readonly telemetry: TelemetryService,
  ) {}

  async run({ repositoryId }: RepositoryPruneData, ctx: JobContext): Promise<void> {
    const repository = await this.repository.get(repositoryId);
    if (!repository) {
      throw new NotFoundException('Repository not found locally');
    }

    const { retentionPolicy } = repository;
    if (!retentionPolicy) {
      throw new Error('No retention policy configured for this repository');
    }

    this.telemetry.submitStructuredLog('Running repository prune', {
      repositoryId,
      retentionPolicy,
    });

    const { endpoint, key, placement } = await this.repositoryService.getResticParameters(repositoryId);

    let error;
    try {
      await this.restic.unlockAll(endpoint, key, placement);

      const events = await this.restic.forgetByPolicy(endpoint, key, placement, retentionPolicy, ctx.signal);
      for (const { keep, remove, reasons } of events) {
        for (const { id, time } of keep ?? []) {
          ctx.logWriter.write(
            JSON.stringify({
              message_type: 'yucca_prune_kept',
              id,
              time,
              matches: reasons?.find((reason) => reason.snapshot.id === id)?.matches,
            }) + '\n',
          );
        }

        for (const { id, time } of remove ?? []) {
          ctx.logWriter.write(JSON.stringify({ message_type: 'yucca_prune_removed', id, time }) + '\n');
        }
      }

      await this.restic.prune(endpoint, key, placement, ctx.signal);
    } catch (error_) {
      error = error_;
    }

    await this.jobs.queue({ name: JobName.RepositorySyncMetrics, data: { repositoryId } });

    this.telemetry.submitStructuredLog('Finished repository prune', {
      repositoryId,
      error,
    });

    if (error) {
      throw error;
    }
  }
}
