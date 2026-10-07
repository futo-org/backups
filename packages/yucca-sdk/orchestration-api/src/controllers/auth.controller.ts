import { Body, Controller, Post, Req, Res, Sse } from '@nestjs/common';
import { ApiBody, ApiCreatedResponse, ApiOkResponse } from '@nestjs/swagger';
import { type Request, type Response } from 'express';
import { SESSION_TTL_MS } from '../const.js';
import { CreateSessionRequestDto, DeviceFlowEventDto } from '../dto/auth.dto.js';
import { TicketCreateRequestDto, TicketCreateResponseDto } from '../dto/ticket.dto.js';
import { CookieName } from '../enum.js';
import { PublicRoute } from '../middleware/session.guard.js';
import { AuthService } from '../services/auth.service.js';
import { SessionService } from '../services/session.service.js';

@Controller('/yucca/auth')
export class AuthController {
  constructor(
    readonly auth: AuthService,
    readonly session: SessionService,
  ) {}

  @Sse('/oidc/device')
  @ApiOkResponse({ type: DeviceFlowEventDto })
  connectDeviceFlow() {
    return this.auth.deviceFlow(false);
  }

  @Sse('/session/device')
  @PublicRoute()
  @ApiOkResponse({ type: DeviceFlowEventDto })
  sessionDeviceFlow() {
    return this.auth.deviceFlow(true);
  }

  @Post('/session')
  @PublicRoute()
  @ApiBody({ type: CreateSessionRequestDto })
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
  async createTicket(@Body() dto: TicketCreateRequestDto): Promise<TicketCreateResponseDto> {
    return await this.auth.createTicket(dto);
  }
}
