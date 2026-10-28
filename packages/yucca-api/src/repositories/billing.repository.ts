import { Injectable } from '@nestjs/common';
import { Insertable, Kysely, sql } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from 'src/schema/index.js';
import { BillingStatementTable } from 'src/schema/tables/billingStatement.table.js';
import { BillingState } from 'src/schema/tables/user.table.js';

@Injectable()
export class BillingRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  getUserBilling(userId: string) {
    return this.db
      .selectFrom('users')
      .select(['id', 'sub', 'email', 'billingStatus', 'billingState', 'billingUpdatedAt'])
      .where('id', '=', userId)
      .executeTakeFirst();
  }

  findUser({ sub, email }: { sub: string | null; email: string | null }) {
    return this.db
      .selectFrom('users')
      .select(['id', 'sub', 'email'])
      .where((eb) =>
        eb.or([
          ...(sub ? [eb('sub', '=', sub)] : []),
          ...(email ? [eb(sql`lower(email)`, '=', email.toLowerCase())] : []),
        ]),
      )
      .orderBy(sql`case when sub = ${sub ?? ''} then 0 else 1 end`)
      .executeTakeFirst();
  }

  /** Every account, newest first, with whether it currently holds a session. */
  listUsers(limit: number) {
    return this.db
      .selectFrom('users')
      .select((eb) => [
        'id',
        'sub',
        'email',
        'name',
        'createdAt',
        'billingStatus',
        eb
          .exists(eb.selectFrom('sessions').select('sessions.id').whereRef('sessions.userId', '=', 'users.id'))
          .as('signedIn'),
      ])
      .where('disabled', '=', false)
      .orderBy('createdAt', 'desc')
      .limit(limit)
      .execute();
  }

  listRepositories(userId: string) {
    return this.db
      .selectFrom('repositories')
      .select(['id', 'name', 'worm', 'connectionId', 'siteCode', 'storageClusterCode'])
      .where('userId', '=', userId)
      .orderBy('name')
      .execute();
  }

  setBillingState(userId: string, status: string, state: BillingState) {
    return this.db
      .updateTable('users')
      .set({ billingStatus: status, billingState: state, billingUpdatedAt: new Date() })
      .where('id', '=', userId)
      .execute();
  }

  async recordDelivery(id: string, event: string): Promise<boolean> {
    const row = await this.db
      .insertInto('billingWebhookDeliveries')
      .values({ id, event })
      .onConflict((oc) => oc.column('id').doNothing())
      .returning('id')
      .executeTakeFirst();
    return row !== undefined;
  }

  listDeliveries(limit: number) {
    return this.db
      .selectFrom('billingWebhookDeliveries')
      .select(['id', 'event', 'receivedAt'])
      .orderBy('receivedAt', 'desc')
      .limit(limit)
      .execute();
  }

  upsertStatement(statement: Insertable<BillingStatementTable> & { usageIds: string[] }) {
    // postgres.js serializes a parameter whose type is jsonb itself, so the
    // values go in as they are: a JSON string here is stored double-encoded
    const values = {
      ...statement,
      usageIds: sql<string[]>`${statement.usageIds}::jsonb`,
      raw: sql<Record<string, unknown>>`${statement.raw}::jsonb`,
    };
    return this.db
      .insertInto('billingStatements')
      .values(values)
      .onConflict((oc) => oc.column('orderId').doNothing())
      .execute();
  }

  listStatements(userId: string) {
    return this.db
      .selectFrom('billingStatements')
      .select([
        'orderId',
        'billingReason',
        'periodStart',
        'periodEnd',
        'gigabyteMonthsUsed',
        'amountCents',
        'currency',
        'createdAt',
      ])
      .where('userId', '=', userId)
      .orderBy('createdAt', 'desc')
      .execute();
  }
}
