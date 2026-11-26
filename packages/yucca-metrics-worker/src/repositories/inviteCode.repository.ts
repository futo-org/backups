import { Injectable } from '@nestjs/common';
import { Kysely } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from 'src/schema/index.js';

export type InviteCodeUsage = {
  name: string;
  uses: number;
  maxUses: number | null;
};

@Injectable()
export class InviteCodeRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  async countUses(): Promise<InviteCodeUsage[]> {
    const rows = await this.db
      .selectFrom('inviteCodes')
      .leftJoin('inviteCodeRedemptions', 'inviteCodeRedemptions.inviteCodeId', 'inviteCodes.id')
      .select(['inviteCodes.name', 'inviteCodes.maxUses'])
      .select((eb) => eb.fn.count<string>('inviteCodeRedemptions.id').as('uses'))
      .groupBy('inviteCodes.id')
      .execute();

    return rows.map(({ name, maxUses, uses }) => ({ name, maxUses, uses: Number(uses) }));
  }
}
