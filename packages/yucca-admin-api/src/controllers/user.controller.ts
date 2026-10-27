import { Body, Controller, Delete, Get, HttpCode, HttpStatus, Param, Patch, Put, Query } from '@nestjs/common';
import { ApiOkResponse } from '@nestjs/swagger';
import { AuthDto } from 'src/dto/auth.dto.js';
import { ConnectionListResponseDto } from 'src/dto/connection.dto.js';
import { FeatureOverrideDto, FeatureOverrideSetRequestDto, UserFeaturesResponseDto } from 'src/dto/features.dto.js';
import { SessionListResponseDto } from 'src/dto/session.dto.js';
import { SupportLogSessionListResponseDto } from 'src/dto/supportLog.dto.js';
import {
  UserDiscordLinkDto,
  UserDiscordLinkRequestDto,
  UserGetResponseDto,
  UserListQueryDto,
  UserListResponseDto,
  UserUpdateRequestDto,
  UserUpdateResponseDto,
} from 'src/dto/user.dto.js';
import { Auth, AuthRoute } from 'src/middleware/auth.guard.js';
import { ConnectionRepository } from 'src/repositories/connection.repository.js';
import { SupportLogSessionRepository } from 'src/repositories/supportLogSession.repository.js';
import { FeaturesService } from 'src/services/features.service.js';
import { SessionService } from 'src/services/session.service.js';
import { UserService } from 'src/services/user.service.js';

@Controller('/user')
export class UserController {
  constructor(
    private readonly user: UserService,
    private readonly session: SessionService,
    private readonly features: FeaturesService,
    private readonly connections: ConnectionRepository,
    private readonly supportLogSessions: SupportLogSessionRepository,
  ) {}

  @Get()
  @AuthRoute()
  @ApiOkResponse({ type: UserListResponseDto })
  listUsers(@Query() query: UserListQueryDto): Promise<UserListResponseDto> {
    return this.user.list(query);
  }

  @Get('/:id')
  @AuthRoute()
  @ApiOkResponse({ type: UserGetResponseDto })
  getUser(@Param('id') id: string): Promise<UserGetResponseDto> {
    return this.user.get(id);
  }

  @Patch('/:id')
  @AuthRoute()
  @ApiOkResponse({ type: UserUpdateResponseDto })
  updateUser(@Param('id') id: string, @Body() dto: UserUpdateRequestDto): Promise<UserUpdateResponseDto> {
    return this.user.update(id, dto);
  }

  @Delete('/:id')
  @AuthRoute()
  @HttpCode(HttpStatus.NO_CONTENT)
  deleteUser(@Param('id') id: string): Promise<void> {
    return this.user.delete(id);
  }

  @Put('/:id/discord')
  @AuthRoute()
  @ApiOkResponse({ type: UserDiscordLinkDto })
  linkUserDiscord(@Param('id') id: string, @Body() dto: UserDiscordLinkRequestDto): Promise<UserDiscordLinkDto> {
    return this.user.linkDiscord(id, dto);
  }

  @Delete('/:id/discord')
  @AuthRoute()
  @HttpCode(HttpStatus.NO_CONTENT)
  unlinkUserDiscord(@Param('id') id: string): Promise<void> {
    return this.user.unlinkDiscord(id);
  }

  @Get('/:userId/session')
  @AuthRoute()
  @ApiOkResponse({ type: SessionListResponseDto })
  listUserSessions(@Param('userId') userId: string): Promise<SessionListResponseDto> {
    return this.session.listForUser(userId);
  }

  @Delete('/:userId/session')
  @AuthRoute()
  @HttpCode(HttpStatus.NO_CONTENT)
  deleteUserSessions(@Param('userId') userId: string): Promise<void> {
    return this.session.deleteForUser(userId);
  }

  @Get('/:id/features')
  @AuthRoute()
  @ApiOkResponse({ type: UserFeaturesResponseDto })
  getUserFeatures(@Param('id') id: string): Promise<UserFeaturesResponseDto> {
    return this.features.getForUser(id);
  }

  @Put('/:id/features/:flag')
  @AuthRoute()
  @ApiOkResponse({ type: FeatureOverrideDto })
  setUserFeature(
    @Auth() auth: AuthDto,
    @Param('id') id: string,
    @Param('flag') flag: string,
    @Body() dto: FeatureOverrideSetRequestDto,
  ): Promise<FeatureOverrideDto> {
    return this.features.set(auth, id, flag, dto);
  }

  @Delete('/:id/features/:flag')
  @AuthRoute()
  @HttpCode(HttpStatus.NO_CONTENT)
  clearUserFeature(@Auth() auth: AuthDto, @Param('id') id: string, @Param('flag') flag: string): Promise<void> {
    return this.features.clear(auth, id, flag);
  }

  @Get('/:id/connections')
  @AuthRoute()
  @ApiOkResponse({ type: ConnectionListResponseDto })
  async listUserConnections(@Param('id') id: string): Promise<ConnectionListResponseDto> {
    return { connections: await this.connections.getByUser(id) };
  }

  @Get('/:id/support-log-sessions')
  @AuthRoute()
  @ApiOkResponse({ type: SupportLogSessionListResponseDto })
  async listUserSupportLogSessions(@Param('id') id: string): Promise<SupportLogSessionListResponseDto> {
    return { sessions: await this.supportLogSessions.getByUser(id) };
  }
}
