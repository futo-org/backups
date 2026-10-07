import { Body, Controller, Get, Post, Res } from '@nestjs/common';
import { ApiCreatedResponse, ApiOkResponse, ApiOperation } from '@nestjs/swagger';
import {
  ConfigureImmichDatabaseDumpRequestDto,
  ConfigureImmichIntegrationRequestDto,
  ConfigureImmichIntegrationResponseDto,
  ImmichBackupStatusDto,
  ImmichRollbackRequestDto,
  IntegrationsResponseDto,
} from '../dto/integrations.dto.js';

import { type Response } from 'express';
import { ImmichCookie } from '../enum.js';
import { IntegrationsService } from '../services/integrations.service.js';

@Controller('/yucca/integrations')
export class IntegrationsController {
  constructor(private readonly service: IntegrationsService) {}

  @Get()
  @ApiOkResponse({ type: IntegrationsResponseDto })
  @ApiOperation({
    summary: 'Get backup integrations',
    description: 'Retrieve the configuration and state of each integration.',
  })
  getIntegrations(): Promise<IntegrationsResponseDto> {
    return this.service.getIntegrationsConfig();
  }

  @Get('immich/status')
  @ApiOkResponse({ type: ImmichBackupStatusDto })
  @ApiOperation({
    summary: 'Get Immich backup status',
    description: 'Retrieve the backup status of the Immich integration.',
  })
  getImmichBackupStatus(): Promise<ImmichBackupStatusDto> {
    return this.service.getImmichBackupStatus();
  }

  @Post('immich')
  @ApiCreatedResponse({ type: ConfigureImmichIntegrationResponseDto })
  @ApiOperation({
    summary: 'Configure the Immich backup integration',
    description: 'Set up backups for the Immich backup integration.',
  })
  configureImmichIntegration(
    @Body() dto: ConfigureImmichIntegrationRequestDto,
  ): Promise<ConfigureImmichIntegrationResponseDto> {
    return this.service.configureImmichIntegration(dto);
  }

  @Post('immich/database-dump/ignore-warning')
  @ApiOperation({
    summary: 'Ignore the Immich database dump warning',
    description: 'Stop warning that Immich database dumps are not configured.',
  })
  @ApiCreatedResponse()
  ignoreImmichDatabaseDumpWarning(): Promise<void> {
    return this.service.ignoreImmichDatabaseDumpWarning();
  }

  @Post('immich/database-dump')
  @ApiOperation({
    summary: 'Configure Immich database dumps',
    description: 'Configure the Immich database dumps included in backups.',
  })
  @ApiCreatedResponse()
  configureImmichDatabaseDump(@Body() dto: ConfigureImmichDatabaseDumpRequestDto): Promise<void> {
    return this.service.configureImmichDatabaseDump(dto);
  }

  @Post('immich/rollback')
  @ApiOperation({
    summary: 'Roll Immich back to a snapshot',
    description: 'Put Immich into maintenance mode and restore it from a snapshot.',
  })
  @ApiCreatedResponse()
  async startImmichRollback(@Body() dto: ImmichRollbackRequestDto, @Res({ passthrough: true }) response: Response) {
    const { jwt } = await this.service.enterImmichMaintenanceRollback(dto);
    response.cookie(ImmichCookie.MaintenanceToken, jwt);
  }
}
