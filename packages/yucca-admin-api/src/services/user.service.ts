import { ConflictException, Injectable, NotFoundException } from '@nestjs/common';
import { NoResultError } from 'kysely';
import {
  UserDiscordLinkDto,
  UserDiscordLinkRequestDto,
  UserGetResponseDto,
  UserListQueryDto,
  UserListResponseDto,
  UserUpdateRequestDto,
  UserUpdateResponseDto,
} from 'src/dto/user.dto.js';
import { DiscordLinkRepository } from 'src/repositories/discordLink.repository.js';
import { SessionRepository } from 'src/repositories/session.repository.js';
import { UserRepository } from 'src/repositories/user.repository.js';
import { resolveLimit } from 'src/utils/pagination.js';

@Injectable()
export class UserService {
  constructor(
    private readonly users: UserRepository,
    private readonly sessions: SessionRepository,
    private readonly discordLinks: DiscordLinkRepository,
  ) {}

  list(query: UserListQueryDto): Promise<UserListResponseDto> {
    return this.users.list({ cursor: query.cursor, limit: resolveLimit(query.limit) });
  }

  async get(id: string): Promise<UserGetResponseDto> {
    const [user, link] = await Promise.all([this.getUser(id), this.discordLinks.getByUserId(id)]);
    return { user, discordLink: link ? toDiscordLinkDto(link) : null };
  }

  async linkDiscord(id: string, dto: UserDiscordLinkRequestDto): Promise<UserDiscordLinkDto> {
    await this.getUser(id);
    const link = await this.discordLinks.link(id, dto.discordUserId, dto.discordUsername ?? '');
    return toDiscordLinkDto(link);
  }

  async unlinkDiscord(id: string): Promise<void> {
    if (!(await this.discordLinks.unlink(id))) {
      throw new NotFoundException(`No discord link for user ${id}`);
    }
  }

  async update(id: string, dto: UserUpdateRequestDto): Promise<UserUpdateResponseDto> {
    if (dto.disabled === true) {
      await this.sessions.deleteByUser(id);
    }
    await this.users.update(id, dto);
    return { user: await this.getUser(id) };
  }

  async delete(id: string): Promise<void> {
    if (await this.users.hasRepositories(id)) {
      throw new ConflictException('Cannot delete a user that still owns repositories');
    }
    await this.users.delete(id);
  }

  private getUser(id: string) {
    return this.users.get(id).catch((error: unknown) => {
      throw error instanceof NoResultError ? new NotFoundException(`No user with id ${id}`) : error;
    });
  }
}

const toDiscordLinkDto = (link: {
  discordUserId: string;
  discordUsername: string;
  createdAt: Date;
}): UserDiscordLinkDto => ({
  discordUserId: link.discordUserId,
  discordUsername: link.discordUsername,
  createdAt: link.createdAt,
});
