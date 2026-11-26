import { ConflictException, Injectable, NotFoundException } from '@nestjs/common';
import {
  InviteCodeCreateRequestDto,
  InviteCodeDto,
  InviteCodeGetResponseDto,
  InviteCodeListResponseDto,
  InviteCodeResponseDto,
} from 'src/dto/inviteCode.dto.js';
import { env } from 'src/env.js';
import { InviteCodeRepository } from 'src/repositories/inviteCode.repository.js';
import { generateInviteCode } from 'src/utils/invite-code.js';

type InviteCodeRow = NonNullable<Awaited<ReturnType<InviteCodeRepository['get']>>>;

@Injectable()
export class InviteCodeService {
  constructor(private readonly inviteCodes: InviteCodeRepository) {}

  async list(): Promise<InviteCodeListResponseDto> {
    const inviteCodes = await this.inviteCodes.list();
    return { items: inviteCodes.map((inviteCode) => this.toDto(inviteCode)) };
  }

  async get(id: string): Promise<InviteCodeGetResponseDto> {
    const inviteCode = await this.getOrThrow(id);
    const redemptions = await this.inviteCodes.listRedemptions(id);
    return { inviteCode: this.toDto(inviteCode), redemptions };
  }

  async create(dto: InviteCodeCreateRequestDto): Promise<InviteCodeResponseDto> {
    const code = dto.code ?? generateInviteCode();
    if (await this.inviteCodes.isTaken({ name: dto.name, code })) {
      throw new ConflictException('An invite code with this name or code already exists');
    }

    const inviteCode = await this.inviteCodes.create({
      name: dto.name,
      code,
      maxUses: dto.maxUses ?? null,
      expiresAt: dto.expiresAt ?? null,
    });
    return { inviteCode: this.toDto(inviteCode) };
  }

  async revoke(id: string): Promise<InviteCodeResponseDto> {
    await this.getOrThrow(id);
    await this.inviteCodes.revoke(id);
    return { inviteCode: this.toDto(await this.getOrThrow(id)) };
  }

  private async getOrThrow(id: string): Promise<InviteCodeRow> {
    const inviteCode = await this.inviteCodes.get(id);
    if (!inviteCode) {
      throw new NotFoundException(`No invite code with id ${id}`);
    }
    return inviteCode;
  }

  private toDto(inviteCode: InviteCodeRow): InviteCodeDto {
    const inviteUrl = new URL('/login/invite', env.WEB_BASE_URL);
    inviteUrl.searchParams.set('code', inviteCode.code);
    return {
      id: inviteCode.id,
      name: inviteCode.name,
      code: inviteCode.code,
      inviteUrl: inviteUrl.href,
      maxUses: inviteCode.maxUses,
      uses: Number(inviteCode.uses),
      expiresAt: inviteCode.expiresAt,
      revokedAt: inviteCode.revokedAt,
      createdAt: inviteCode.createdAt,
    };
  }
}
