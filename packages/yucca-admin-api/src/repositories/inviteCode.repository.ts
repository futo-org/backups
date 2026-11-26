import { Injectable } from '@nestjs/common';
import { Insertable, Kysely, sql } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from 'src/schema/index.js';
import { InviteCodeTable } from 'src/schema/tables/inviteCode.table.js';

@Injectable()
export class InviteCodeRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  list() {
    return this.withUses().orderBy('inviteCodes.createdAt', 'desc').execute();
  }

  get(id: string) {
    return this.withUses()
      .where('inviteCodes.id', '=', sql<string>`${id}::uuid`)
      .executeTakeFirst();
  }

  listRedemptions(inviteCodeId: string) {
    return this.db
      .selectFrom('inviteCodeRedemptions')
      .innerJoin('users', 'users.id', 'inviteCodeRedemptions.userId')
      .select(['inviteCodeRedemptions.userId', 'users.email', 'inviteCodeRedemptions.createdAt'])
      .where('inviteCodeRedemptions.inviteCodeId', '=', sql<string>`${inviteCodeId}::uuid`)
      .orderBy('inviteCodeRedemptions.createdAt', 'desc')
      .execute();
  }

  async isTaken({ name, code }: { name: string; code: string }) {
    const [inviteCode, allowlistEntry] = await Promise.all([
      this.db
        .selectFrom('inviteCodes')
        .select('id')
        .where((eb) => eb.or([eb('name', '=', name), eb('code', '=', code)]))
        .executeTakeFirst(),
      this.db.selectFrom('userAllowlist').select('id').where('inviteCode', '=', code).executeTakeFirst(),
    ]);
    return inviteCode !== undefined || allowlistEntry !== undefined;
  }

  async create(inviteCode: Insertable<InviteCodeTable>) {
    const { id } = await this.db.insertInto('inviteCodes').values(inviteCode).returning('id').executeTakeFirstOrThrow();
    return (await this.get(id))!;
  }

  async revoke(id: string) {
    await this.db
      .updateTable('inviteCodes')
      .set({ revokedAt: new Date() })
      .where('id', '=', sql<string>`${id}::uuid`)
      .where('revokedAt', 'is', null)
      .execute();
  }

  private withUses() {
    return this.db
      .selectFrom('inviteCodes')
      .leftJoin('inviteCodeRedemptions', 'inviteCodeRedemptions.inviteCodeId', 'inviteCodes.id')
      .selectAll('inviteCodes')
      .select((eb) => eb.fn.count<string>('inviteCodeRedemptions.id').as('uses'))
      .groupBy('inviteCodes.id');
  }
}
