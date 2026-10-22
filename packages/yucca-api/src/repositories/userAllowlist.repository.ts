import { Injectable } from '@nestjs/common';
import { Kysely, sql } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { inTransaction } from 'src/repositories/transaction.js';
import { DB } from 'src/schema/index.js';

@Injectable()
export class UserAllowlistRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  getByEmail(email: string) {
    return this.db.selectFrom('userAllowlist').selectAll().where('email', '=', email).executeTakeFirst();
  }

  markUsed(id: string) {
    return this.consume('id', id);
  }

  consumeInviteCode(inviteCode: string) {
    return this.consume('inviteCode', inviteCode);
  }

  private consume(field: 'id' | 'inviteCode', value: string) {
    return inTransaction(this.db, async (trx) => {
      const entry = await trx.selectFrom('userAllowlist').selectAll().where(field, '=', value).executeTakeFirst();
      if (!entry) {
        return;
      }
      if (entry.discordUserId) {
        await sql`SELECT pg_advisory_xact_lock(hashtext(${entry.discordUserId}))`.execute(trx);
      }
      if (entry.batchId) {
        await sql`SELECT pg_advisory_xact_lock(hashtext(${entry.batchId}))`.execute(trx);
      }
      const consumed = await trx
        .updateTable('userAllowlist')
        .set({ inviteUsed: true, inviteUsedAt: sql<Date>`clock_timestamp()` })
        .where('id', '=', entry.id)
        .where(field, '=', value)
        .where('inviteUsed', '=', false)
        .where((eb) =>
          eb.or([
            eb('batchId', 'is', null),
            eb.exists(
              eb
                .selectFrom('discordLinkRequests')
                .select('id')
                .whereRef('allowlistId', '=', 'userAllowlist.id')
                .where('expiresAt', '>', sql<Date>`clock_timestamp()`),
            ),
          ]),
        )
        .returning('id')
        .executeTakeFirst();
      if (consumed) {
        await trx.deleteFrom('discordLinkRequests').where('allowlistId', '=', consumed.id).execute();
      }
      return consumed;
    });
  }
}
