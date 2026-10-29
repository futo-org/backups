import { Body, Controller, Post, Req, Res, Sse } from '@nestjs/common';
import { ApiBody, ApiCreatedResponse, ApiOkResponse, ApiOperation } from '@nestjs/swagger';
import { type Request, type Response } from 'express';
import { SESSION_TTL_MS } from '../const.js';
import { CreateSessionRequestDto, DeviceFlowEventDto } from '../dto/auth.dto.js';
import { TicketCreateRequestDto, TicketCreateResponseDto } from '../dto/ticket.dto.js';
import { CookieName } from '../enum.js';
import { PublicRoute } from '../middleware/session.guard.js';
import { AuthService } from '../services/auth.service.js';
import { SessionService } from '../services/session.service.js';

@Controller('/futo-backups/auth')
export class AuthController {
  constructor(
    readonly auth: AuthService,
    readonly session: SessionService,
  ) {}

  @Sse('/oidc/device')
  @ApiOkResponse({ type: DeviceFlowEventDto })
  @ApiOperation({
    operationId: 'futoBackupsConnectDeviceFlow',
    summary: 'Connect a FUTO Backups account',
    description: 'Connect an existing FUTO Backups account to this server.',
  })
  connectDeviceFlow() {
    return this.auth.deviceFlow(false);
  }

  @Sse('/session/device')
  @PublicRoute()
  @ApiOkResponse({ type: DeviceFlowEventDto })
  @ApiOperation({
    operationId: 'futoBackupsSessionDeviceFlow',
    summary: 'Sign in with FUTO Backups account',
    description: 'Log into standalone backups app using the associated cloud account.',
  })
  sessionDeviceFlow() {
    return this.auth.deviceFlow(true);
  }

  @Post('/session')
  @PublicRoute()
  @ApiBody({ type: CreateSessionRequestDto })
  @ApiOperation({
    operationId: 'futoBackupsCreateSession',
    summary: 'Create session',
    description: 'Use existing session token to create a session on your device.',
  })
  @ApiCreatedResponse()
  async createSession(
    @Body() dto: CreateSessionRequestDto,
    @Req() request: Request,
    @Res({ passthrough: true }) response: Response,
  ) {
    await this.session.authenticate(dto.token);

    response.cookie(CookieName.SessionToken, dto.token, {
      path: '/',
      httpOnly: true,
      sameSite: 'lax',
      secure: request.protocol === 'https',
      maxAge: SESSION_TTL_MS,
    });
  }

  @Post('/ticket')
  @ApiCreatedResponse({ type: TicketCreateResponseDto })
  @ApiOperation({
    operationId: 'futoBackupsCreateTicket',
    summary: 'Create a ticket',
    description: 'Create a ticket to perform a protected repository action.',
  })
  async createTicket(@Body() dto: TicketCreateRequestDto): Promise<TicketCreateResponseDto> {
    return await this.auth.createTicket(dto);
  }
}
