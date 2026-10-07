import { Injectable } from '@nestjs/common';
import { CurrentRecoveryKeyResponse, OnboardingStatusResponseDto } from '../dto/onboarding.dto.js';
import { BootstrapStatus, TelemetryLevel } from '../enum.js';
import { BackendRepository } from '../repositories/backend.repository.js';
import { BootstrapRepository } from '../repositories/bootstrap.repository.js';
import { ConfigRepository } from '../repositories/config.repository.js';
import { RepositoryRepository } from '../repositories/repository.repository.js';
import { ScheduleRepository } from '../repositories/schedule.repository.js';
import { Session, SessionService } from './session.service.js';
import { TelemetryService } from './telemetry.service.js';

@Injectable()
export class OnboardingService {
  constructor(
    private readonly backend: BackendRepository,
    private readonly repository: RepositoryRepository,
    private readonly schedule: ScheduleRepository,
    private readonly config: ConfigRepository,
    private readonly bootstrap: BootstrapRepository,
    private readonly telemetry: TelemetryService,
    private readonly session: SessionService,
  ) {}

  async onboardingStatus(session?: Session): Promise<OnboardingStatusResponseDto> {
    const status = this.bootstrap.getStatus();
    const configuration = await this.session.cloudConfiguration();
    const requiresAuthentication = this.session.isRequired(configuration);
    const isAuthenticated = session !== undefined;

    if (status !== BootstrapStatus.Ready) {
      let error = this.bootstrap.getError();
      error = error ? `${error}` : undefined;

      return {
        status,
        error,
        hasTelemetry: TelemetryLevel.None,
        requiresAuthentication,
        isAuthenticated,
        hasOnboardedKey: false,
        hasBackend: false,
        hasBackup: false,
        hasSchedule: false,
        hasSkippedExtraConfig: false,
      };
    }

    const backends = await this.backend.getBackends();
    const repositories = await this.repository.getAll();
    const schedules = await this.schedule.getAll();

    return {
      status: BootstrapStatus.Ready,
      hasTelemetry: (await this.config.hasTelemetry()) ? TelemetryLevel.Full : TelemetryLevel.None,
      requiresAuthentication,
      isAuthenticated,
      hasOnboardedKey: await this.config.hasOnboardedKey(),
      hasBackend: backends.length > 0,
      hasBackup: repositories.length > 0,
      hasSchedule: schedules.length > 0,
      hasSkippedExtraConfig: await this.config.hasSkippedExtraConfig(),
    };
  }

  async currentRecoveryKey(): Promise<CurrentRecoveryKeyResponse> {
    const recoveryKey = await this.config.getMasterEncryptionKey();

    return {
      recoveryKey,
    };
  }

  async importRecoveryKey(key: string) {
    await this.config.importEncryptionKey(key);
  }

  async confirmRecoveryKey() {
    await this.config.confirmKeyOnboarded();
  }

  async skipExtraConfig() {
    await this.config.skipExtraConfig();
  }

  async enableTelemetry() {
    await this.config.enableTelemetry();

    this.telemetry.submitStructuredLog('Telemetry consent granted', {});
  }

  reportError() {
    this.telemetry.submitStructuredLog(
      'Bootstrap error',
      {
        error: this.bootstrap.getError(),
      },
      true,
    );
  }
}
