import {
  adoptRepositories,
  getAuth,
  oidcDeviceAuthorize,
  oidcDeviceIdentity,
  oidcDeviceToken,
  TicketCreateRequestDto,
} from '@futo-org/backups-api-client';
import { BadGatewayException, BadRequestException, GoneException, Injectable, NotFoundException } from '@nestjs/common';
import { hostname } from 'node:os';
import { REPOSITORY_DEFAULT_CLOUD_UUID } from '../const.js';
import { DeviceFlowIdentityPollRequestDto, DeviceFlowPollDto, DeviceFlowStartDto } from '../dto/auth.dto.js';
import { TicketCreateResponseDto } from '../dto/ticket.dto.js';
import { BackendType, CookieName, DeviceFlowFailureReason, DeviceFlowPollStatus } from '../enum.js';
import { EventsGateway } from '../events/events.gateway.js';
import { BackendRepository } from '../repositories/backend.repository.js';
import { ConfigRepository } from '../repositories/config.repository.js';
import { ModuleConfigRepository } from '../repositories/moduleConfig.repository.js';
import { RepositoryRepository } from '../repositories/repository.repository.js';
import { isNotFoundError } from '../utils/errors.js';
import { yuccaWellKnown } from '../wellKnown.js';
import { SessionService } from './session.service.js';
import { TelemetryService } from './telemetry.service.js';

@Injectable()
export class AuthService {
  constructor(
    readonly config: ConfigRepository,
    readonly backend: BackendRepository,
    readonly moduleConfig: ModuleConfigRepository,
    readonly events: EventsGateway,
    readonly telemetry: TelemetryService,
    readonly repository: RepositoryRepository,
    readonly session: SessionService,
  ) {}

  private connectionType(): string {
    return this.moduleConfig.get().immichIntegration ? 'immich' : 'standalone';
  }

  private connectionName(): string {
    const fallback = hostname() || this.connectionType();
    const external = this.moduleConfig.get().externalBaseUrl;
    if (external) {
      try {
        return new URL(external).host;
      } catch {
        return fallback;
      }
    }

    return fallback;
  }

  private async adoptOwnRepositories(endpoint: string | undefined, accessToken: string): Promise<void> {
    try {
      const requestOptions = {
        baseUrl: endpoint,
        headers: { cookie: `${CookieName.YuccaAccessToken}=${accessToken}` },
      };

      const auth = await getAuth(requestOptions);
      if (!auth.connectionId) {
        return;
      }

      const repositories = await this.repository.getAll();
      const repositoryIds = repositories
        .filter((row) => row.backendId === REPOSITORY_DEFAULT_CLOUD_UUID)
        .map((row) => row.remoteId);
      if (repositoryIds.length === 0) {
        return;
      }

      await adoptRepositories(auth.connectionId, { repositoryIds }, requestOptions);
      this.telemetry.submitStructuredLog('Adopted repositories into instance connection', {
        connectionId: auth.connectionId,
        count: repositoryIds.length,
      });
    } catch (error) {
      this.telemetry.submitStructuredLog('Repository adoption skipped', { error: String(error) });
    }
  }

  private async fetchBackendUserId(endpoint: string, accessToken: string): Promise<string> {
    const auth = await getAuth({
      baseUrl: endpoint,
      headers: { cookie: `${CookieName.YuccaAccessToken}=${accessToken}` },
    });

    return auth.id;
  }

  private async connectBackend(endpoint: string, accessToken: string, userId: string): Promise<void> {
    await this.backend.updateBackend(REPOSITORY_DEFAULT_CLOUD_UUID, {
      type: BackendType.Yucca,
      accessToken,
      userId,
    });

    await this.adoptOwnRepositories(endpoint, accessToken);

    this.telemetry.submitStructuredLog('Connected FUTO Backups backend', {
      backendId: REPOSITORY_DEFAULT_CLOUD_UUID,
    });

    this.events.publish({
      type: 'BackendCreate',
      backend: {
        id: REPOSITORY_DEFAULT_CLOUD_UUID,
        type: BackendType.Yucca,
        description: 'FUTO Backups',
        isOnline: true,
      },
    });
  }

  async connectDeviceAuthorize(): Promise<DeviceFlowStartDto> {
    try {
      const endpoint = await yuccaWellKnown.getBaseUrl();
      return await oidcDeviceAuthorize({ baseUrl: endpoint });
    } catch (error) {
      this.telemetry.submitStructuredLog('Device flow authentication errored', { error });
      throw new BadGatewayException({
        message: 'Could not start a FUTO Backups login',
        reason: DeviceFlowFailureReason.Unknown,
      });
    }
  }

  async connectDeviceToken(dto: DeviceFlowIdentityPollRequestDto): Promise<DeviceFlowPollDto> {
    try {
      const endpoint = await yuccaWellKnown.getBaseUrl();
      const pollResult = await oidcDeviceToken(
        {
          deviceCode: dto.deviceCode,
          connectionType: this.connectionType(),
          connectionName: this.connectionName(),
        },
        { baseUrl: endpoint },
      );

      if (pollResult.status === 'FAILURE') {
        this.telemetry.submitStructuredLog('Device flow authentication failed', { reason: pollResult.reason });
        return { status: DeviceFlowPollStatus.Failure, reason: DeviceFlowFailureReason.DeviceFlowFailed };
      }

      if (pollResult.status !== 'SUCCESS') {
        return { status: pollResult.status as DeviceFlowPollStatus };
      }

      if (!pollResult.userId) {
        throw new Error('Device flow succeeded without a user');
      }

      if (!pollResult.accessToken) {
        throw new Error('Device flow succeeded without an access token');
      }

      await this.connectBackend(endpoint, pollResult.accessToken, pollResult.userId);

      const configuration = await this.session.cloudConfiguration();
      const accessToken = this.session.isRequired(configuration)
        ? await this.session.issue(pollResult.userId)
        : undefined;

      return { status: DeviceFlowPollStatus.Success, accessToken, backendId: REPOSITORY_DEFAULT_CLOUD_UUID };
    } catch (error) {
      this.telemetry.submitStructuredLog('Device flow authentication errored', { error });
      return { status: DeviceFlowPollStatus.Failure, reason: DeviceFlowFailureReason.Unknown };
    }
  }

  async sessionDeviceAuthorize(): Promise<DeviceFlowStartDto> {
    const cloud = await this.session.cloudConfiguration();
    if (!cloud) {
      throw new BadRequestException({
        message: 'Connect this instance to a FUTO Backups account before signing in',
        reason: DeviceFlowFailureReason.NotConnected,
      });
    }

    return this.connectDeviceAuthorize();
  }

  async sessionDeviceToken(dto: DeviceFlowIdentityPollRequestDto): Promise<DeviceFlowPollDto> {
    try {
      const cloud = await this.session.cloudConfiguration();
      if (!cloud) {
        return { status: DeviceFlowPollStatus.Failure, reason: DeviceFlowFailureReason.NotConnected };
      }

      const endpoint = await yuccaWellKnown.getBaseUrl();
      const pollResult = await oidcDeviceIdentity({ deviceCode: dto.deviceCode }, { baseUrl: endpoint });

      if (pollResult.status === 'FAILURE') {
        this.telemetry.submitStructuredLog('Device flow authentication failed', { reason: pollResult.reason });
        return { status: DeviceFlowPollStatus.Failure, reason: DeviceFlowFailureReason.DeviceFlowFailed };
      }

      if (pollResult.status !== 'SUCCESS') {
        return { status: pollResult.status as DeviceFlowPollStatus };
      }

      if (!pollResult.userId) {
        throw new Error('Device flow succeeded without a user');
      }

      let claimedUserId = cloud.userId;

      if (!claimedUserId) {
        claimedUserId = await this.fetchBackendUserId(endpoint, cloud.accessToken);
        await this.backend.updateBackend(REPOSITORY_DEFAULT_CLOUD_UUID, { ...cloud, userId: claimedUserId });
      }

      if (pollResult.userId !== claimedUserId) {
        return { status: DeviceFlowPollStatus.Failure, reason: DeviceFlowFailureReason.WrongAccount };
      }

      const accessToken = this.session.isRequired(cloud) ? await this.session.issue(pollResult.userId) : undefined;

      return { status: DeviceFlowPollStatus.Success, accessToken };
    } catch (error) {
      this.telemetry.submitStructuredLog('Device flow authentication errored', { error });
      return { status: DeviceFlowPollStatus.Failure, reason: DeviceFlowFailureReason.Unknown };
    }
  }

  async createTicket(dto: TicketCreateRequestDto): Promise<TicketCreateResponseDto> {
    const localRepository = await this.repository.get(dto.repositoryId);
    if (!localRepository) {
      throw new NotFoundException('Repository not found locally');
    }

    const result = await this.backend.getBackend(localRepository.backendId);
    if (!result) {
      throw new NotFoundException('Backend not found locally');
    }

    try {
      return await result.backend.createTicket({
        action: dto.action,
        repositoryId: localRepository.remoteId,
      });
    } catch (error) {
      if (isNotFoundError(error)) {
        throw new GoneException('Repository not found remotely');
      }

      throw error;
    }
  }
}
