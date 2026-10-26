import { Injectable } from '@nestjs/common';
import { ResticTagPrefix } from '../enum.js';
import { EventsGateway, GatewayEvent } from '../events/events.gateway.js';
import type { ImmichIntegration } from '../moduleConfig.js';
import { JobRepository } from '../repositories/job.repository.js';
import { ModuleConfigRepository } from '../repositories/moduleConfig.repository.js';
import { RepositoryService } from './repository.service.js';

@Injectable()
export class YuccaService {
  constructor(
    private readonly moduleConfig: ModuleConfigRepository,
    private readonly events: EventsGateway,
    private readonly repositoryService: RepositoryService,
    private readonly jobs: JobRepository,
  ) {}

  setExternalBaseUrl(externalBaseUrl: string) {
    this.moduleConfig.update({ externalBaseUrl });
  }

  setImmichIntegration(immichIntegration: ImmichIntegration) {
    this.moduleConfig.update({ immichIntegration });
  }

  acquireLock() {
    this.moduleConfig.acquireLock();
  }

  emit(event: GatewayEvent) {
    this.events.emit(event);
    void this.jobs.onEvent(event);
  }

  async restoreSnapshotInplace(repositoryId: string, snapshotId: string) {
    const { snapshot } = await this.repositoryService.getSnapshot(repositoryId, snapshotId);
    const immichBackupFileName = snapshot.tags
      ?.find((tag) => tag.startsWith(`${ResticTagPrefix.ImmichBackupFileName}=`))
      ?.slice(ResticTagPrefix.ImmichBackupFileName.length + 1);

    const { jobId } = await this.repositoryService.restoreSnapshot(repositoryId, snapshotId, {});

    return {
      jobId,
      task: this.jobs.wait(jobId),
      immichBackupFileName,
    };
  }
}
