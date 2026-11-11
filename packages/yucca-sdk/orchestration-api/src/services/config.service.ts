import { Injectable } from '@nestjs/common';
import {
  ConfigResponseDto,
  ConfigUpdateRequestDto,
  ConnectionsDto,
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
    const automatic = await this.getAutomaticConnections();

    return {
      override,
      automatic: automatic.connections,
      effective: override ?? automatic.connections,
      source: override ? ConnectionsSource.Override : automatic.source,
      min: MIN_CONNECTIONS,
      max: MAX_CONNECTIONS,
    };
  }

  private async getAutomaticConnections() {
    const repositories = await this.repository.getAll();
    const placed = repositories.find(({ siteCode }) => siteCode);
    const placement = placed ? { siteCode: placed.siteCode, storageClusterCode: placed.storageClusterCode } : UNPLACED;

    try {
      return await this.config.getAutomaticConnections(placement);
    } catch {
      return this.config.getAutomaticConnections(UNPLACED);
    }
  }
}
