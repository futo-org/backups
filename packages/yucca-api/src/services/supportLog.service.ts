import { WideContextRepository } from '@common/server/otel';
import { Injectable, NotFoundException, Scope, ServiceUnavailableException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { Selectable } from 'kysely';
import { AuthDto } from 'src/dto/auth.dto.js';
import {
  SupportLogSessionCreateRequestDto,
  SupportLogSessionStatsRequestDto,
  SupportLogSessionTokenDto,
} from 'src/dto/supportLog.dto.js';
import { env } from 'src/env.js';
import { SupportLogSessionRepository } from 'src/repositories/supportLogSession.repository.js';
import { SupportLogSessionTable } from 'src/schema/tables/supportLogSession.table.js';

export const SUPPORT_LOGS_AUDIENCE = 'support-logs';
const TOKEN_TTL_SECONDS = 6 * 60 * 60;

@Injectable({ scope: Scope.REQUEST })
export class SupportLogService {
  constructor(
    private readonly sessions: SupportLogSessionRepository,
    private readonly jwt: JwtService,
    private readonly wideContext: WideContextRepository,
  ) {}

  async createSession(auth: AuthDto, dto: SupportLogSessionCreateRequestDto): Promise<SupportLogSessionTokenDto> {
    const url = this.batchesUrl();
    const session = await this.sessions.create({
      userId: auth.id,
      connectionId: auth.connectionId,
      jobId: dto.jobId,
      jobName: dto.jobName,
      includesPaths: dto.includesPaths,
      clientVersion: dto.clientVersion ?? null,
    });

    return this.issueToken(session, url);
  }

  async refreshToken(auth: AuthDto, id: string): Promise<SupportLogSessionTokenDto> {
    const url = this.batchesUrl();
    const session = await this.sessions.getById(id);
    if (!session || session.userId !== auth.id || session.finishedAt) {
      throw new NotFoundException(`No open support log session with id ${id}`);
    }

    return this.issueToken(session, url);
  }

  async recordStats(id: string, { reportId, ...dto }: SupportLogSessionStatsRequestDto) {
    const outcome = await this.sessions.addStats(id, reportId, {
      ...dto,
      lastBatchAt: dto.lastBatchAt ? new Date(dto.lastBatchAt) : undefined,
    });
    if (outcome === 'missing') {
      throw new NotFoundException(`No support log session with id ${id}`);
    }
  }

  private async issueToken(
    session: Selectable<SupportLogSessionTable>,
    url: string,
  ): Promise<SupportLogSessionTokenDto> {
    this.wideContext.addContext('supportLogSessionId', session.id);

    const token = await this.jwt.signAsync(
      {
        sid: session.id,
        job: session.jobId,
        jobName: session.jobName,
        ...(session.connectionId && { connection: session.connectionId }),
      },
      { subject: session.userId, audience: SUPPORT_LOGS_AUDIENCE, expiresIn: TOKEN_TTL_SECONDS },
    );

    return {
      id: session.id,
      token,
      url,
      expiresAt: new Date(Date.now() + TOKEN_TTL_SECONDS * 1000),
    };
  }

  private batchesUrl() {
    if (!env.SUPPORT_LOGS_URL) {
      throw new ServiceUnavailableException('Support log streaming is not configured');
    }

    return `${env.SUPPORT_LOGS_URL.replace(/\/$/, '')}/v1/batches`;
  }
}
