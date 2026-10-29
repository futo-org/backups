import { Body, Controller, Get, Post, Put, Req } from '@nestjs/common';
import { ApiBody, ApiCreatedResponse, ApiOkResponse, ApiOperation } from '@nestjs/swagger';
import {
  CurrentRecoveryKeyResponse,
  ImportRecoveryKeyRequest,
  OnboardingStatusResponseDto,
} from '../dto/onboarding.dto.js';
import { PublicRoute, type SessionRequest } from '../middleware/session.guard.js';
import { OnboardingService } from '../services/onboarding.service.js';

@Controller('/futo-backups/onboarding')
export class OnboardingController {
  constructor(readonly service: OnboardingService) {}

  @Get()
  @PublicRoute()
  @ApiOkResponse({ type: OnboardingStatusResponseDto })
  @ApiOperation({
    operationId: 'futoBackupsOnboardingStatus',
    summary: 'Get backup onboarding status',
    description: 'Retrieve which onboarding steps this server has completed.',
  })
  async onboardingStatus(@Req() request: SessionRequest): Promise<OnboardingStatusResponseDto> {
    return this.service.onboardingStatus(request.session);
  }

  @Get('/recovery-key')
  @ApiOkResponse({ type: CurrentRecoveryKeyResponse })
  @ApiOperation({
    operationId: 'futoBackupsCurrentRecoveryKey',
    summary: 'Get the backup recovery key',
    description: 'Retrieve the recovery key that encrypts the backups of this server.',
  })
  async currentRecoveryKey(): Promise<CurrentRecoveryKeyResponse> {
    return this.service.currentRecoveryKey();
  }

  @Put('/recovery-key')
  @ApiBody({ type: ImportRecoveryKeyRequest })
  @ApiOperation({
    operationId: 'futoBackupsImportRecoveryKey',
    summary: 'Import a backup recovery key',
    description: 'Replace the recovery key with one from an earlier installation.',
  })
  @ApiOkResponse()
  async importRecoveryKey(@Body() dto: ImportRecoveryKeyRequest) {
    await this.service.importRecoveryKey(dto.recoveryKey);
  }

  @Post('/recovery-key')
  @ApiOperation({
    operationId: 'futoBackupsConfirmRecoveryKey',
    summary: 'Confirm the backup recovery key',
    description: 'Record that the user has saved the recovery key.',
  })
  @ApiCreatedResponse()
  async confirmRecoveryKey() {
    await this.service.confirmRecoveryKey();
  }

  @Post('/skip')
  @ApiOperation({
    operationId: 'futoBackupsSkipOnboardingExtraConfig',
    summary: 'Skip optional backup onboarding',
    description: 'Skip the optional configuration steps of onboarding.',
  })
  @ApiCreatedResponse()
  async skipOnboardingExtraConfig() {
    await this.service.skipExtraConfig();
  }

  @Post('/telemetry')
  @ApiOperation({
    operationId: 'futoBackupsEnableTelemetry',
    summary: 'Enable FUTO Backups telemetry',
    description: 'Record that the user consents to sending telemetry.',
  })
  @ApiCreatedResponse()
  async enableTelemetry() {
    await this.service.enableTelemetry();
  }

  @Post('/report-error')
  @ApiOperation({
    operationId: 'futoBackupsReportError',
    summary: 'Report a startup error',
    description: 'Send the current startup error to telemetry.',
  })
  @ApiCreatedResponse()
  reportError() {
    this.service.reportError();
  }
}
