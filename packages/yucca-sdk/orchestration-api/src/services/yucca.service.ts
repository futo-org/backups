import { Injectable } from '@nestjs/common';
import { EventsGateway, GatewayEvent } from '../events/events.gateway.js';
import type { DatabaseHooks, ImmichIntegration } from '../moduleConfig.js';
import { JobRepository } from '../repositories/job.repository.js';
import { ModuleConfigRepository } from '../repositories/moduleConfig.repository.js';
import { getDatabaseBackupFileName } from '../utils/restic.js';
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

  setDatabaseHooks(databaseHooks: DatabaseHooks) {
    this.moduleConfig.update({ databaseHooks });
  }

  setImmichIntegration(immichIntegration: ImmichIntegration) {
    this.moduleConfig.update({ immichIntegration });
  }

  emit(event: GatewayEvent) {
    this.events.emit(event);
    void this.jobs.onEvent(event);
  }

  async restoreSnapshotInplace(repositoryId: string, snapshotId: string) {
    const { snapshot } = await this.repositoryService.getSnapshot(repositoryId, snapshotId);
    const { databaseHooks } = this.moduleConfig.get();
    const immichBackupFileName = databaseHooks && getDatabaseBackupFileName(snapshot.tags, databaseHooks.tagName);

    const { jobId } = await this.repositoryService.restoreSnapshot(repositoryId, snapshotId, {});

    return {
      jobId,
      task: this.jobs.wait(jobId),
      immichBackupFileName,
    };
  }
}
