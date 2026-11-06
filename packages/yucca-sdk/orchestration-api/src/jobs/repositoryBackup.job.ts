import { ResticBackupCommandCouldNotReadSourceDataError } from '@futo-org/restic-wrapper';
import { NotFoundException } from '@nestjs/common';
import { relative, resolve } from 'node:path';
import { Job } from '../decorators.js';
import { JobName, TaskStatus } from '../enum.js';
import type { ResticPlacement } from '../repositories/config.repository.js';
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

      const { databaseHooks, statePath } = this.moduleConfig.get();
      const immichIntegration = await this.repositoryIntegrationImmich.get();
      const pathsIncludeState = paths.some((path) => !relative(resolve(path), resolve(statePath)).startsWith('..'));
      const dumpDatabase = repositoryId === immichIntegration?.id || pathsIncludeState;
      if (databaseHooks && dumpDatabase) {
        this.telemetry.submitStructuredLog('Creating database backup', {
          repositoryId,
        });

        try {
          const backupFileName = await databaseHooks.dump(ctx.signal);
          tags.push(`${databaseHooks.tagName}=${backupFileName}`);

          this.telemetry.submitStructuredLog('Created database backup', {
            repositoryId,
          });
        } catch (error) {
          this.telemetry.submitStructuredLog('Failed to create database backup', {
            repositoryId,
            error,
          });

          warnings.push(new Error(`Database dump failed: ${error}`, { cause: error }));
        }
      }

      await this.restic.unlockAll(endpoint, key, placement);
      const parent = await this.findParentSnapshot(repositoryId, endpoint, key, placement, ctx.signal);
      const previousBytes = parent?.totalBytes || undefined;
      if (previousBytes !== undefined) {
        ctx.expectTotalBytes(previousBytes);
      }

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
          parent?.id,
          previousBytes !== undefined,
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

      if (databaseHooks?.cleanup && dumpDatabase) {
        try {
          await databaseHooks.cleanup();
        } catch (error) {
          this.telemetry.submitStructuredLog('Failed to clean up database backups', {
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
          lastBackup: new Date(),
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

  private async findParentSnapshot(
    repositoryId: string,
    endpoint: string,
    key: Uint8Array,
    placement: ResticPlacement,
    signal: AbortSignal,
  ): Promise<{ id: string; totalBytes?: number } | undefined> {
    const last = await this.jobs.getLastBackup(repositoryId);
    if (!last) {
      return;
    }

    const { snapshotId, totalBytes } = last;
    try {
      const snapshots = await this.restic.snapshot(endpoint, key, placement, snapshotId, signal);
      if (snapshots.some(({ id }) => id === snapshotId)) {
        return { id: snapshotId, totalBytes };
      }

      this.telemetry.submitStructuredLog('Previous snapshot no longer exists, choosing the parent by paths', {
        repositoryId,
        snapshotId,
      });
    } catch (error) {
      signal.throwIfAborted();
      this.telemetry.submitStructuredLog('Failed to look up the previous snapshot, choosing the parent by paths', {
        repositoryId,
        snapshotId,
        error,
      });
    }
  }
}
