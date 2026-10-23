import { ResticBackupCommandCouldNotReadSourceDataError } from '@futo-org/restic-wrapper';
import { NotFoundException } from '@nestjs/common';
import { Job } from '../decorators.js';
import { JobName, ResticTagPrefix, TaskStatus } from '../enum.js';
import type { ImmichIntegration } from '../moduleConfig.js';
import { JobRepository } from '../repositories/job.repository.js';
import { ModuleConfigRepository } from '../repositories/moduleConfig.repository.js';
import { RepositoryRepository } from '../repositories/repository.repository.js';
import { RepositoryIntegrationImmichRepository } from '../repositories/repositoryIntegrationImmich.repository.js';
import { RepositoryPathRepository } from '../repositories/repositoryPath.repository.js';
import { ResticRepository } from '../repositories/restic.repository.js';
import { RepositoryService } from '../services/repository.service.js';
import { TelemetryService } from '../services/telemetry.service.js';
import { getTaskStatus, TaskWarningsError } from '../utils/errors.js';
import type { JobHandler } from '../utils/types.js';
import { JobContext } from './jobContext.js';

type RepositoryBackupData = {
  repositoryId: string;
};

@Job({ name: JobName.RepositoryBackup })
export class RepositoryBackupJob implements JobHandler<RepositoryBackupData> {
  constructor(
    private readonly repositoryService: RepositoryService,
    private readonly repository: RepositoryRepository,
    private readonly repositoryPath: RepositoryPathRepository,
    private readonly repositoryIntegrationImmich: RepositoryIntegrationImmichRepository,
    private readonly moduleConfig: ModuleConfigRepository,
    private readonly restic: ResticRepository,
    private readonly jobs: JobRepository,
    private readonly telemetry: TelemetryService,
  ) {}

  async run({ repositoryId }: RepositoryBackupData, ctx: JobContext): Promise<void> {
    this.telemetry.submitStructuredLog('Running backup', {
      repositoryId,
    });

    const repository = await this.repository.get(repositoryId);
    if (!repository) {
      throw new NotFoundException('Repository not found locally');
    }

    const { backendId, remoteId, retentionPolicy } = repository;
    const { backend } = await this.repositoryService.getBackendOrThrow(backendId);
    const { endpoint, key, placement } = await this.repositoryService.getResticParameters(repositoryId);

    const paths = await this.repositoryPath.get(repositoryId);
    if (paths.length === 0) {
      throw new Error('Missing configuration paths');
    }

    const startTime = Date.now();

    if (backend.isMetricsCapable()) {
      backend.submitMetricBackupStart(remoteId);
    }

    let error;
    let pruneQueued = false;
    try {
      const warnings: Error[] = [];
      const tags = [];

      let immichHooks: ImmichIntegration['hooks'] | undefined;

      const config = this.moduleConfig.get();
      if (config.immichIntegration) {
        const immichIntegration = await this.repositoryIntegrationImmich.get();
        if (repositoryId === immichIntegration?.id) {
          immichHooks = config.immichIntegration.hooks;
          this.telemetry.submitStructuredLog('Creating Immich database backup', {
            repositoryId,
          });

          try {
            const backupFileName = await immichHooks.createDatabaseBackup(ctx.signal);
            tags.push(`${ResticTagPrefix.ImmichBackupFileName}=${backupFileName}`);

            this.telemetry.submitStructuredLog('Created Immich database backup', {
              repositoryId,
            });
          } catch (error) {
            this.telemetry.submitStructuredLog('Failed to create Immich database backup', {
              repositoryId,
              error,
            });

            warnings.push(new Error(`Database dump failed: ${error}`, { cause: error }));
          }
        }
      }

      await this.restic.unlockAll(endpoint, key, placement);
      let summary;
      try {
        summary = await this.restic.backup(
          endpoint,
          key,
          placement,
          paths,
          (event) => ctx.log(event),
          ctx.signal,
          tags,
        );
      } catch (backupError) {
        if (!(backupError instanceof ResticBackupCommandCouldNotReadSourceDataError)) {
          throw backupError;
        }

        warnings.push(backupError);
      }

      this.telemetry.submitStructuredLog('Finished backup to primary backend', {
        repositoryId,
        summary,
      });

      if (immichHooks) {
        try {
          await immichHooks.cleanupDatabaseBackups();
        } catch (error) {
          this.telemetry.submitStructuredLog('Failed to clean up Immich database backups', {
            repositoryId,
            error,
          });

          warnings.push(new Error(`Database backup cleanup failed: ${error}`, { cause: error }));
        }
      }

      if (retentionPolicy && warnings.length === 0) {
        await this.jobs.queue({ name: JobName.RepositoryPrune, data: { repositoryId } });
        pruneQueued = true;
      }

      if (warnings.length > 0) {
        throw new TaskWarningsError(warnings);
      }
    } catch (error_) {
      error = error_;
    }

    try {
      const lastBackupStatus = getTaskStatus(error);
      const lastBackupDuration = Date.now() - startTime;

      await this.repositoryService.updateLocalMetrics(repositoryId, {
        additionalMetrics: {
          lastBackup: new Date().toISOString(),
          lastBackupStatus,
          lastBackupDuration,
        },
      });

      if (lastBackupStatus !== TaskStatus.Cancelled && !pruneQueued) {
        await this.jobs.queue({ name: JobName.RepositorySyncMetrics, data: { repositoryId } });
      }

      this.telemetry.submitStructuredLog('Backup finished', {
        repositoryId,
        lastBackupStatus,
        error,
      });

      if (backend.isMetricsCapable()) {
        backend.submitMetricBackupEnd(remoteId, lastBackupStatus, lastBackupDuration);
      }
    } catch (finaliseError) {
      this.telemetry.submitStructuredLog('Failed to finalise backup', {
        repositoryId,
        error: finaliseError,
      });
    }

    if (error) {
      throw error;
    }
  }
}
