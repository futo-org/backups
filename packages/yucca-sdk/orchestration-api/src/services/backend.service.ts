import { Injectable } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { createBackend } from '../backends/createBackend.js';
import { YuccaBackend } from '../backends/yucca.backend.js';
import { REPOSITORY_DEFAULT_CLOUD_UUID } from '../const.js';
import { BackendResponseDto, BackendsResponseDto, CreateLocalBackendRequestDto } from '../dto/backend.dto.js';
import { BackendType } from '../enum.js';
import { EventsGateway } from '../events/events.gateway.js';
import { BackendRepository } from '../repositories/backend.repository.js';
import { TelemetryService } from './telemetry.service.js';

@Injectable()
export class BackendService {
  constructor(
    private readonly repository: BackendRepository,
    private readonly events: EventsGateway,
    private readonly telemetry: TelemetryService,
  ) {}

  async getBackends(): Promise<BackendsResponseDto> {
    const backends = await this.repository.getBackends();

    const error = await Promise.all(
      backends.map((backend) =>
        createBackend(backend.configuration)
          .checkOnline()
          .then(() => void 0)
          .catch((error) => error),
      ),
    );

    return {
      backends: backends.map((backend, idx) => ({
        id: backend.id,
        type: backend.configuration.type,
        description:
          backend.configuration.type === BackendType.Yucca
            ? backend.configuration.url || 'FUTO Backups'
            : backend.configuration.type === BackendType.Local
              ? backend.configuration.path
              : backend.configuration.endpoint,
        isOnline: error[idx] === undefined,
        error: error[idx],
      })),
    };
  }

  async isCloudFeatureEnabled(feature: string): Promise<boolean> {
    const cloud = await this.repository.getBackend(REPOSITORY_DEFAULT_CLOUD_UUID);
    if (!(cloud?.backend instanceof YuccaBackend)) {
      return false;
    }

    const features = await cloud.backend.getFeatures();
    return features[feature] === true;
  }

  async createLocalBackend(dto: CreateLocalBackendRequestDto): Promise<BackendResponseDto> {
    const { id } = await this.repository.updateBackend(randomUUID(), {
      type: BackendType.Local,
      path: dto.path,
    });

    const backend = {
      type: BackendType.Local,
      id,
      description: dto.path,
      isOnline: true,
    };

    this.telemetry.submitStructuredLog('Created backend', {
      backendId: id,
      type: BackendType.Local,
    });

    this.events.publish({
      type: 'BackendCreate',
      backend,
    });

    return { backend };
  }
}
