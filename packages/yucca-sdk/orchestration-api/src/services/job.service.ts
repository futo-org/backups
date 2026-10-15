import { Injectable } from '@nestjs/common';
import { JobName, JobStatus } from '../enum.js';
import { BackendRepository } from '../repositories/backend.repository.js';
import { JobRepository } from '../repositories/job.repository.js';
import { RepositoryRepository } from '../repositories/repository.repository.js';
import { TelemetryService } from './telemetry.service.js';

@Injectable()
export class JobService {
  constructor(
    private readonly jobs: JobRepository,
    private readonly repository: RepositoryRepository,
    private readonly backend: BackendRepository,
    private readonly telemetry: TelemetryService,
  ) {}

  async bootstrap() {
    const interrupted = await this.jobs.start();

    for (const job of interrupted) {
      if (job.name !== JobName.RepositoryBackup) {
        continue;
      }

      try {
        this.telemetry.submitStructuredLog('Backup finished', {
          repositoryId: job.repositoryId,
          lastBackupStatus: JobStatus.Incomplete,
          error: 'Interrupted before it could report a result, reconciled at startup',
        });

        const repository = await this.repository.get(job.repositoryId);
        if (!repository) {
          continue;
        }

        const result = await this.backend.getBackend(repository.backendId);
        if (result?.backend.isMetricsCapable()) {
          result.backend.submitMetricBackupEnd(
            repository.remoteId,
            JobStatus.Incomplete,
            Date.now() - +new Date(job.start ?? job.queuedAt),
          );
        }
      } catch (error) {
        this.telemetry.submitStructuredLog('Failed to finalise interrupted backup', {
          repositoryId: job.repositoryId,
          error,
        });
      }
    }
  }
}
