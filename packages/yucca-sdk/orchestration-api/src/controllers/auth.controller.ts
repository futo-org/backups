import { Body, Controller, HttpCode, HttpStatus, Post, Req, Res } from '@nestjs/common';
import { ApiBody, ApiCreatedResponse, ApiOkResponse, ApiOperation } from '@nestjs/swagger';
import { type Request, type Response } from 'express';
import { SESSION_TTL_MS } from '../const.js';
import {
  CreateSessionRequestDto,
  DeviceFlowIdentityPollRequestDto,
  DeviceFlowPollDto,
  DeviceFlowStartDto,
} from '../dto/auth.dto.js';
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

  @Post('/oidc/device/authorize')
  @ApiCreatedResponse({ type: DeviceFlowStartDto })
  @ApiOperation({
    operationId: 'futoBackupsConnectDeviceAuthorize',
    summary: 'Start connecting a FUTO Backups account',
    description: 'Start a device login to connect a FUTO Backups account to this server.',
  })
  connectDeviceAuthorize(): Promise<DeviceFlowStartDto> {
    return this.auth.connectDeviceAuthorize();
  }

  @Post('/oidc/device/token')
  @HttpCode(HttpStatus.OK)
  @ApiOkResponse({ type: DeviceFlowPollDto })
  @ApiOperation({
    operationId: 'futoBackupsConnectDeviceToken',
    summary: 'Poll a FUTO Backups account connection',
    description: 'Poll a device login and connect the FUTO Backups account once it is approved.',
  })
  connectDeviceToken(@Body() dto: DeviceFlowIdentityPollRequestDto): Promise<DeviceFlowPollDto> {
    return this.auth.connectDeviceToken(dto);
  }

  @Post('/session/device/authorize')
  @PublicRoute()
  @ApiCreatedResponse({ type: DeviceFlowStartDto })
  @ApiOperation({
    operationId: 'futoBackupsSessionDeviceAuthorize',
    summary: 'Start signing in with FUTO Backups account',
    description: 'Start a device login to sign in to the standalone backups app.',
  })
  sessionDeviceAuthorize(): Promise<DeviceFlowStartDto> {
    return this.auth.sessionDeviceAuthorize();
  }

  @Post('/session/device/token')
  @PublicRoute()
  @HttpCode(HttpStatus.OK)
  @ApiOkResponse({ type: DeviceFlowPollDto })
  @ApiOperation({
    operationId: 'futoBackupsSessionDeviceToken',
    summary: 'Poll a FUTO Backups account sign in',
    description: 'Poll a device login and issue a session token once it is approved.',
  })
  sessionDeviceToken(@Body() dto: DeviceFlowIdentityPollRequestDto): Promise<DeviceFlowPollDto> {
    return this.auth.sessionDeviceToken(dto);
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
