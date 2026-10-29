import { Controller, Post } from '@nestjs/common';
import { ApiCreatedResponse, ApiOperation } from '@nestjs/swagger';
import { DevelopmentService } from '../services/development.service.js';

@Controller('/futo-backups/debug')
export class DevelopmentController {
  constructor(private readonly service: DevelopmentService) {}

  @Post('reset')
  @ApiOperation({
    operationId: 'futoBackupsResetOrchestrator',
    summary: 'Reset the backups orchestrator',
    description: 'Delete all orchestrator state. Only available in development mode.',
  })
  @ApiCreatedResponse()
  async resetOrchestrator(): Promise<void> {
    return this.service.resetOrchestrator();
  }
}
