import { Body, Controller, Get, Put } from '@nestjs/common';
import { ApiOkResponse, ApiOperation } from '@nestjs/swagger';
import { SupportModeResponseDto, SupportModeUpdateRequestDto } from '../dto/supportMode.dto.js';
import { SupportModeService } from '../services/supportMode.service.js';

@Controller('/futo-backups/support-mode')
export class SupportModeController {
  constructor(private readonly service: SupportModeService) {}

  @Get()
  @ApiOkResponse({ type: SupportModeResponseDto })
  @ApiOperation({
    operationId: 'futoBackupsGetSupportMode',
    summary: 'Get support mode',
    description: 'Retrieve how many upcoming runs use verbose restic logging, and whether they stream to FUTO.',
  })
  getSupportMode(): Promise<SupportModeResponseDto> {
    return this.service.get();
  }

  @Put()
  @ApiOkResponse({ type: SupportModeResponseDto })
  @ApiOperation({
    operationId: 'futoBackupsUpdateSupportMode',
    summary: 'Update support mode',
    description: 'Set how many upcoming runs use verbose restic logging, and whether they stream to FUTO.',
  })
  updateSupportMode(@Body() dto: SupportModeUpdateRequestDto): Promise<SupportModeResponseDto> {
    return this.service.update(dto);
  }
}
