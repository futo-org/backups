import { Body, Controller, HttpCode, HttpStatus, Param, ParseUUIDPipe, Post, UseGuards } from '@nestjs/common';
import { ApiExcludeController } from '@nestjs/swagger';
import { SupportLogSessionStatsRequestDto } from 'src/dto/supportLog.dto.js';
import { InternalGuard } from 'src/middleware/internal.guard.js';
import { SupportLogService } from 'src/services/supportLog.service.js';

@Controller('/internal/support-logs/sessions')
@UseGuards(InternalGuard)
@ApiExcludeController()
export class SupportLogInternalController {
  constructor(private readonly supportLogs: SupportLogService) {}

  @Post('/:id/stats')
  @HttpCode(HttpStatus.NO_CONTENT)
  recordSupportLogSessionStats(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: SupportLogSessionStatsRequestDto,
  ): Promise<void> {
    return this.supportLogs.recordStats(id, dto);
  }
}
