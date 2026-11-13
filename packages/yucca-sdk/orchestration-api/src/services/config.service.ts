import { Injectable } from '@nestjs/common';
import {
  ConfigResponseDto,
  ConfigUpdateRequestDto,
  ConnectionsDto,
  ConnectionsPlacementDto,
  MAX_CONNECTIONS,
  MIN_CONNECTIONS,
} from '../dto/config.dto.js';
import { ConnectionsSource } from '../enum.js';
import { UNTHROTTLED } from '../proxy/resticProxy.js';
import { ConfigRepository, ResticPlacement } from '../repositories/config.repository.js';
import { ModuleConfigRepository } from '../repositories/moduleConfig.repository.js';
import { RepositoryRepository } from '../repositories/repository.repository.js';

const UNPLACED: ResticPlacement = { siteCode: null, storageClusterCode: null };

@Injectable()
export class ConfigService {
  constructor(
    private readonly config: ConfigRepository,
    private readonly moduleConfig: ModuleConfigRepository,
    private readonly repository: RepositoryRepository,
  ) {}

  async bootstrap() {
    const stored = await this.config.getThrottle();
    if (!stored) {
      return;
    }

    this.moduleConfig.update({ throttle: stored });
  }

  async getConfig(): Promise<ConfigResponseDto> {
    return {
      bandwidth: this.moduleConfig.get().throttle ?? UNTHROTTLED,
      connections: await this.getConnections(),
    };
  }

  async updateConfig({ bandwidth, connections }: ConfigUpdateRequestDto): Promise<ConfigResponseDto> {
    if (bandwidth) {
      await this.config.setThrottle(bandwidth);
      this.moduleConfig.update({ throttle: bandwidth });
    }

    if (connections !== undefined) {
      await this.config.setConnectionsOverride(connections);
    }

    return this.getConfig();
  }

  private async getConnections(): Promise<ConnectionsDto> {
    const override = await this.config.getConnectionsOverride();
    const placements = await this.getPlacements();

    return {
      override,
      placements: await Promise.all(
        placements.map(async (placement): Promise<ConnectionsPlacementDto> => {
          const automatic = await this.getAutomaticConnections(placement);
          return {
            ...placement,
            automatic: automatic.connections,
            effective: override ?? automatic.connections,
            source: override ? ConnectionsSource.Override : automatic.source,
          };
        }),
      ),
      min: MIN_CONNECTIONS,
      max: MAX_CONNECTIONS,
    };
  }

  private async getPlacements(): Promise<ResticPlacement[]> {
    const repositories = await this.repository.getAll();
    const placements = new Map(
      repositories.map(({ siteCode, storageClusterCode }) => [
        `${siteCode}/${storageClusterCode}`,
        { siteCode, storageClusterCode },
      ]),
    );

    return placements.size > 0 ? [...placements.values()] : [UNPLACED];
  }

  private async getAutomaticConnections(placement: ResticPlacement) {
    try {
      return await this.config.getAutomaticConnections(placement);
    } catch {
      return this.config.getAutomaticConnections(UNPLACED);
    }
  }
}
