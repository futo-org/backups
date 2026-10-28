import { join } from 'node:path';
import { Job } from '../decorators.js';
import { RepositorySnapshotRestoreFromPointRequestDto } from '../dto/repository.dto.js';
import { JobName } from '../enum.js';
import { ConfigRepository } from '../repositories/config.repository.js';
import { DatabaseRepository } from '../repositories/database.repository.js';
import { JobRepository } from '../repositories/job.repository.js';
import { ModuleConfigRepository } from '../repositories/moduleConfig.repository.js';
import { ResticRepository } from '../repositories/restic.repository.js';
import { StorageRepository } from '../repositories/storage.repository.js';
import { BootstrapService } from '../services/bootstrap.service.js';
import { RepositoryService } from '../services/repository.service.js';
import { TelemetryService } from '../services/telemetry.service.js';
import type { JobHandler } from '../utils/types.js';
import { JobContext } from './jobContext.js';

type RepositoryRestoreFromPointData = {
  repositoryId: string;
  snapshotId: string;
  backendId: string;
  options: RepositorySnapshotRestoreFromPointRequestDto;
};

@Job({ name: JobName.RepositoryRestoreFromPoint })
export class RepositoryRestoreFromPointJob implements JobHandler<RepositoryRestoreFromPointData> {
  constructor(
    private readonly repositoryService: RepositoryService,
    private readonly restic: ResticRepository,
    private readonly telemetry: TelemetryService,
    private readonly storage: StorageRepository,
    private readonly moduleConfig: ModuleConfigRepository,
    private readonly database: DatabaseRepository,
    private readonly config: ConfigRepository,
    private readonly jobs: JobRepository,
    private readonly bootstrap: BootstrapService,
  ) {}

  async run(
    { repositoryId, snapshotId, backendId, options }: RepositoryRestoreFromPointData,
    ctx: JobContext,
  ): Promise<void> {
    this.telemetry.submitStructuredLog('Running repository restore from point', {
      repositoryId,
      snapshotId,
      backendId,
    });

    const { endpoint, key, placement } = await this.repositoryService.getResticParameters({
      backendId,
      remoteId: repositoryId,
    });

    let summary;
    let error;
    try {
      summary = await this.restic.restore(
        endpoint,
        key,
        placement,
        snapshotId,
        { include: options.include },
        (event) => ctx.log(event),
        ctx.signal,
      );

      if (options.yuccaConfig) {
        const target = await this.storage.tempdir();

        await this.restic.restore(
          endpoint,
          key,
          placement,
          snapshotId,
          { include: [options.yuccaConfig], target },
          (event) => ctx.log(event),
          ctx.signal,
        );

        const { statePath } = this.moduleConfig.get();
        const restoredState = join(target, options.yuccaConfig);

        await this.storage.cp(restoredState, statePath, {
          recursive: true,
          filter: (src) => !src.endsWith('.sqlite3'),
        });

        await this.database.restoreFrom(join(restoredState, 'state.sqlite3'));
        await this.jobs.persistRunning();

        await this.bootstrap.onApplicationBootstrap();
      }

      await this.config.setRestoreAwaitingContinue();
    } catch (error_) {
      error = error_;
    }

    this.telemetry.submitStructuredLog('Finished repository restore from point', {
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
