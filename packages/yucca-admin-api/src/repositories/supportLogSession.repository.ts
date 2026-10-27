import { Injectable } from '@nestjs/common';
import { Kysely } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from 'src/schema/index.js';

@Injectable()
export class SupportLogSessionRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  async getByUser(userId: string, limit = 100) {
    const sessions = await this.db
      .selectFrom('supportLogSessions')
      .selectAll()
      .where('userId', '=', userId)
      .orderBy('createdAt', 'desc')
      .limit(limit)
      .execute();

    return sessions.map((session) => ({
      ...session,
      lineCount: Number(session.lineCount),
      byteCount: Number(session.byteCount),
      batchCount: Number(session.batchCount),
      droppedLineCount: Number(session.droppedLineCount),
    }));
  }
}
