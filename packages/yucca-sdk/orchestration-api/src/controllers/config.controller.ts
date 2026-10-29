import { Body, Controller, Get, Put } from '@nestjs/common';
import { ApiOkResponse, ApiOperation } from '@nestjs/swagger';
import { ConfigResponseDto, ConfigUpdateRequestDto } from '../dto/config.dto.js';
import { ConfigService } from '../services/config.service.js';

@Controller('/futo-backups/config')
export class ConfigController {
  constructor(private readonly service: ConfigService) {}

  @Get()
  @ApiOkResponse({ type: ConfigResponseDto })
  @ApiOperation({
    summary: 'Get backups orchestrator configuration',
    description: 'Retrieve the current backups orchestrator configuration.',
  })
  getConfig(): ConfigResponseDto {
    return this.service.getConfig();
  }

  @Put()
  @ApiOkResponse({ type: ConfigResponseDto })
  @ApiOperation({
    summary: 'Update backups orchestrator configuration',
    description: 'Update the backups orchestrator configuration.',
  })
  updateConfig(@Body() dto: ConfigUpdateRequestDto): Promise<ConfigResponseDto> {
    return this.service.updateConfig(dto);
  }
}
