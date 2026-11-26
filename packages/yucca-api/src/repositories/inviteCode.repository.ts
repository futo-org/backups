import { Injectable } from '@nestjs/common';
import { Kysely, sql } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from 'src/schema/index.js';

@Injectable()
export class InviteCodeRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  // The row lock is held until the registration transaction records its
  // redemption, so concurrent sign-ups cannot overshoot maxUses.
  async claim(code: string): Promise<string | undefined> {
    const inviteCode = await this.db
      .selectFrom('inviteCodes')
      .select(['id', 'maxUses'])
      .where('code', '=', code)
      .where('revokedAt', 'is', null)
      .where((eb) => eb.or([eb('expiresAt', 'is', null), eb('expiresAt', '>', sql<Date>`clock_timestamp()`)]))
      .forUpdate()
      .executeTakeFirst();
    if (!inviteCode) {
      return;
    }

    if (inviteCode.maxUses !== null) {
      const { uses } = await this.db
        .selectFrom('inviteCodeRedemptions')
        .select((eb) => eb.fn.countAll<string>().as('uses'))
        .where('inviteCodeId', '=', inviteCode.id)
        .executeTakeFirstOrThrow();
      if (Number(uses) >= inviteCode.maxUses) {
        return;
      }
    }

    return inviteCode.id;
  }

  async recordRedemption(inviteCodeId: string, userId: string): Promise<void> {
    await this.db.insertInto('inviteCodeRedemptions').values({ inviteCodeId, userId }).execute();
  }
}
