import { Injectable } from '@nestjs/common';
import { Insertable, Kysely, sql } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from 'src/schema/index.js';
import { SupportLogSessionTable } from 'src/schema/tables/supportLogSession.table.js';

export type SupportLogSessionStats = {
  lines: number;
  bytes: number;
  batches: number;
  droppedLines: number;
  lastBatchAt?: Date;
  finished: boolean;
};

@Injectable()
export class SupportLogSessionRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  create(session: Insertable<SupportLogSessionTable>) {
    return this.db.insertInto('supportLogSessions').values(session).returningAll().executeTakeFirstOrThrow();
  }

  getById(id: string) {
    return this.db.selectFrom('supportLogSessions').selectAll().where('id', '=', id).executeTakeFirst();
  }

  addStats(id: string, { lines, bytes, batches, droppedLines, lastBatchAt, finished }: SupportLogSessionStats) {
    return this.db
      .updateTable('supportLogSessions')
      .set((eb) => ({
        lineCount: eb('lineCount', '+', lines),
        byteCount: eb('byteCount', '+', bytes),
        batchCount: eb('batchCount', '+', batches),
        droppedLineCount: eb('droppedLineCount', '+', droppedLines),
        lastBatchAt: lastBatchAt
          ? sql<Date>`greatest(${eb.ref('lastBatchAt')}, ${lastBatchAt})`
          : eb.ref('lastBatchAt'),
        finishedAt: finished ? sql<Date>`coalesce(${eb.ref('finishedAt')}, now())` : eb.ref('finishedAt'),
      }))
      .where('id', '=', id)
      .returning('id')
      .executeTakeFirst();
  }
}
