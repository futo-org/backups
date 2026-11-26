import { Body, Controller, Delete, Get, Param, ParseUUIDPipe, Post } from '@nestjs/common';
import { ApiCreatedResponse, ApiOkResponse } from '@nestjs/swagger';
import {
  InviteCodeCreateRequestDto,
  InviteCodeGetResponseDto,
  InviteCodeListResponseDto,
  InviteCodeResponseDto,
} from 'src/dto/inviteCode.dto.js';
import { AuthRoute } from 'src/middleware/auth.guard.js';
import { InviteCodeService } from 'src/services/inviteCode.service.js';

@Controller('/invite-codes')
export class InviteCodeController {
  constructor(private readonly inviteCodes: InviteCodeService) {}

  @Get()
  @AuthRoute()
  @ApiOkResponse({ type: InviteCodeListResponseDto })
  listInviteCodes(): Promise<InviteCodeListResponseDto> {
    return this.inviteCodes.list();
  }

  @Post()
  @AuthRoute()
  @ApiCreatedResponse({ type: InviteCodeResponseDto })
  createInviteCode(@Body() dto: InviteCodeCreateRequestDto): Promise<InviteCodeResponseDto> {
    return this.inviteCodes.create(dto);
  }

  @Get('/:id')
  @AuthRoute()
  @ApiOkResponse({ type: InviteCodeGetResponseDto })
  getInviteCode(@Param('id', ParseUUIDPipe) id: string): Promise<InviteCodeGetResponseDto> {
    return this.inviteCodes.get(id);
  }

  @Delete('/:id')
  @AuthRoute()
  @ApiOkResponse({ type: InviteCodeResponseDto })
  revokeInviteCode(@Param('id', ParseUUIDPipe) id: string): Promise<InviteCodeResponseDto> {
    return this.inviteCodes.revoke(id);
  }
}
