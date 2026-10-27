import { Body, Controller, Param, ParseUUIDPipe, Post } from '@nestjs/common';
import { ApiCreatedResponse, ApiTags } from '@nestjs/swagger';
import { ZodSerializerDto } from 'nestjs-zod';
import { AuthDto } from 'src/dto/auth.dto.js';
import { SupportLogSessionCreateRequestDto, SupportLogSessionTokenDto } from 'src/dto/supportLog.dto.js';
import { Auth, AuthRoute, RequireFeature } from 'src/middleware/auth.guard.js';
import { SupportLogService } from 'src/services/supportLog.service.js';

@ApiTags('support-logs')
@Controller('/support-logs/sessions')
export class SupportLogController {
  constructor(private readonly supportLogs: SupportLogService) {}

  @Post()
  @AuthRoute()
  @RequireFeature('support-log-streaming')
  @ApiCreatedResponse({ type: SupportLogSessionTokenDto })
  @ZodSerializerDto(SupportLogSessionTokenDto)
  createSupportLogSession(
    @Auth() auth: AuthDto,
    @Body() dto: SupportLogSessionCreateRequestDto,
  ): Promise<SupportLogSessionTokenDto> {
    return this.supportLogs.createSession(auth, dto);
  }

  @Post('/:id/token')
  @AuthRoute()
  @RequireFeature('support-log-streaming')
  @ApiCreatedResponse({ type: SupportLogSessionTokenDto })
  @ZodSerializerDto(SupportLogSessionTokenDto)
  refreshSupportLogSessionToken(
    @Auth() auth: AuthDto,
    @Param('id', ParseUUIDPipe) id: string,
  ): Promise<SupportLogSessionTokenDto> {
    return this.supportLogs.refreshToken(auth, id);
  }
}
