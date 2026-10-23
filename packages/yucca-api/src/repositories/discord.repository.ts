import { Injectable } from '@nestjs/common';
import { Insertable, Kysely, Selectable, Updateable, sql } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { env } from 'src/env.js';
import { inTransaction } from 'src/repositories/transaction.js';
import { DB } from 'src/schema/index.js';
import { DiscordInviteBatchTable } from 'src/schema/tables/discordInviteBatch.table.js';
import { DiscordLinkRequestTable } from 'src/schema/tables/discordLinkRequest.table.js';
import { DiscordTicketTable } from 'src/schema/tables/discordTicket.table.js';

export type InviteClaimResult =
  | { status: 'linked' | 'used' | 'unknownBatch' | 'exhausted' | 'cancelled' }
  | { status: 'ok'; request: Selectable<DiscordLinkRequestTable>; remaining: number | null };

@Injectable()
export class DiscordRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  createRequest(request: Insertable<DiscordLinkRequestTable>) {
    return this.db.insertInto('discordLinkRequests').values(request).returningAll().executeTakeFirstOrThrow();
  }

  getRequestByCode(code: string) {
    return this.db.selectFrom('discordLinkRequests').selectAll().where('code', '=', code).executeTakeFirst();
  }

  async deleteExpiredRequests() {
    await this.db.deleteFrom('discordLinkRequests').where('expiresAt', '<', new Date()).execute();
  }

  consumeInviteRequest(code: string) {
    return inTransaction(this.db, async (trx) => {
      const request = await trx
        .selectFrom('discordLinkRequests')
        .innerJoin('userAllowlist', 'userAllowlist.id', 'discordLinkRequests.allowlistId')
        .selectAll('discordLinkRequests')
        .select('userAllowlist.batchId')
        .where('discordLinkRequests.code', '=', code)
        .executeTakeFirst();
      if (!request?.allowlistId) {
        return;
      }
      await sql`SELECT pg_advisory_xact_lock(hashtext(${request.discordUserId}))`.execute(trx);
      if (request.batchId) {
        await sql`SELECT pg_advisory_xact_lock(hashtext(${request.batchId}))`.execute(trx);
      }
      const consumed = await trx
        .deleteFrom('discordLinkRequests')
        .where('code', '=', code)
        .where('expiresAt', '>', sql<Date>`clock_timestamp()`)
        .returningAll()
        .executeTakeFirst();
      if (!consumed) {
        return;
      }
      const entry = await trx
        .updateTable('userAllowlist')
        .set({ inviteUsed: true, inviteUsedAt: sql<Date>`clock_timestamp()` })
        .where('id', '=', request.allowlistId)
        .where('inviteUsed', '=', false)
        .returning('id')
        .executeTakeFirst();
      if (!entry) {
        return;
      }
      await trx.deleteFrom('discordLinkRequests').where('allowlistId', '=', entry.id).execute();
      return consumed;
    });
  }

  getLinkByDiscordUserId(discordUserId: string) {
    return this.db.selectFrom('discordLinks').selectAll().where('discordUserId', '=', discordUserId).executeTakeFirst();
  }

  getLinkByUserId(userId: string) {
    return this.db.selectFrom('discordLinks').selectAll().where('userId', '=', userId).executeTakeFirst();
  }

  link(requestId: string, userId: string, discordUserId: string, discordUsername: string) {
    return inTransaction(
      this.db,
      async (trx) => {
        await sql`SELECT pg_advisory_xact_lock(least(hashtext(${userId}), hashtext(${discordUserId}))),
                       pg_advisory_xact_lock(greatest(hashtext(${userId}), hashtext(${discordUserId})))`.execute(trx);
        const consumed = await trx
          .deleteFrom('discordLinkRequests')
          .where('id', '=', requestId)
          .where('allowlistId', 'is', null)
          .where('expiresAt', '>', new Date())
          .returning('id')
          .executeTakeFirst();
        if (!consumed) {
          return null;
        }
        await trx
          .deleteFrom('discordLinks')
          .where((eb) => eb.or([eb('userId', '=', userId), eb('discordUserId', '=', discordUserId)]))
          .execute();
        return trx
          .insertInto('discordLinks')
          .values({ userId, discordUserId, discordUsername })
          .returningAll()
          .executeTakeFirstOrThrow();
      },
      { retryDeadlocks: true },
    );
  }

  linkDirect(userId: string, discordUserId: string, discordUsername: string) {
    return inTransaction(
      this.db,
      async (trx) => {
        await sql`SELECT pg_advisory_xact_lock(least(hashtext(${userId}), hashtext(${discordUserId}))),
                       pg_advisory_xact_lock(greatest(hashtext(${userId}), hashtext(${discordUserId})))`.execute(trx);
        await trx
          .deleteFrom('discordLinks')
          .where((eb) => eb.or([eb('userId', '=', userId), eb('discordUserId', '=', discordUserId)]))
          .execute();
        return trx
          .insertInto('discordLinks')
          .values({ userId, discordUserId, discordUsername })
          .returningAll()
          .executeTakeFirstOrThrow();
      },
      { retryDeadlocks: true },
    );
  }

  async updateUsername(discordUserId: string, discordUsername: string): Promise<boolean> {
    const updated = await this.db
      .updateTable('discordLinks')
      .set({ discordUsername })
      .where('discordUserId', '=', discordUserId)
      .returning('id')
      .executeTakeFirst();
    return updated !== undefined;
  }

  createBatch(batch: Insertable<DiscordInviteBatchTable>) {
    return this.db.insertInto('discordInviteBatches').values(batch).returningAll().executeTakeFirstOrThrow();
  }

  async setBatchMessage(batchId: string, messageId: string): Promise<boolean> {
    const updated = await this.db
      .updateTable('discordInviteBatches')
      .set({ messageId })
      .where('id', '=', batchId)
      .returning('id')
      .executeTakeFirst();
    return updated !== undefined;
  }

  claimInvite(
    discordUserId: string,
    discordUsername: string,
    batchId: string | null,
    inviteCode: string,
    request: { code: string; expiresAt: Date },
  ): Promise<InviteClaimResult> {
    return inTransaction(this.db, async (trx): Promise<InviteClaimResult> => {
      await sql`SELECT pg_advisory_xact_lock(hashtext(${discordUserId}))`.execute(trx);

      const previous = await trx
        .selectFrom('userAllowlist')
        .select('batchId')
        .where('discordUserId', '=', discordUserId)
        .executeTakeFirst();
      const batchIds = [
        ...new Set([batchId, previous?.batchId].filter((id): id is string => typeof id === 'string')),
      ].toSorted();
      for (const id of batchIds) {
        await sql`SELECT pg_advisory_xact_lock(hashtext(${id}))`.execute(trx);
        await this.recycleExpiredInvites(trx, id);
      }

      const link = await trx
        .selectFrom('discordLinks')
        .select('id')
        .where('discordUserId', '=', discordUserId)
        .executeTakeFirst();
      if (link) {
        return { status: 'linked' };
      }

      const existing = await trx
        .selectFrom('userAllowlist')
        .selectAll()
        .where('discordUserId', '=', discordUserId)
        .executeTakeFirst();
      if (existing?.inviteUsed) {
        return { status: 'used' };
      }

      let remaining: number | null = null;
      for (const id of batchIds) {
        if (id !== batchId && id !== existing?.batchId) {
          continue;
        }
        const batch = await trx.selectFrom('discordInviteBatches').selectAll().where('id', '=', id).executeTakeFirst();
        if (!batch) {
          return { status: 'unknownBatch' };
        }
        if (batch.cancelledAt) {
          return { status: 'cancelled' };
        }
        const { claimed } = await trx
          .selectFrom('userAllowlist')
          .select((eb) => eb.fn.countAll<number>().as('claimed'))
          .where('batchId', '=', id)
          .executeTakeFirstOrThrow();
        if (!existing && id === batchId && Number(claimed) >= batch.maxClaims) {
          return { status: 'exhausted' };
        }
        if (id === batchId) {
          remaining = Math.max(0, batch.maxClaims - Number(claimed) - (existing ? 0 : 1));
        }
      }

      const entry =
        existing ??
        (await trx
          .insertInto('userAllowlist')
          .values({ inviteCode, invited: true, discordUserId, discordUsername, batchId })
          .returningAll()
          .executeTakeFirstOrThrow());
      await trx.deleteFrom('discordLinkRequests').where('allowlistId', '=', entry.id).execute();
      const created = await trx
        .insertInto('discordLinkRequests')
        .values({ ...request, discordUserId, discordUsername, allowlistId: entry.id })
        .returningAll()
        .executeTakeFirstOrThrow();
      return { status: 'ok', request: created, remaining };
    });
  }

  async listInviteBatches() {
    const batches = await this.db
      .selectFrom('discordInviteBatches')
      .select('id')
      .where('messageId', 'is not', null)
      .orderBy('createdAt', 'asc')
      .execute();
    const statuses = await Promise.all(batches.map(({ id }) => this.getInviteBatch(id)));
    return statuses.filter((batch) => batch !== undefined);
  }

  getInviteBatch(batchId: string) {
    return inTransaction(this.db, async (trx) => {
      await sql`SELECT pg_advisory_xact_lock(hashtext(${batchId}))`.execute(trx);
      await this.recycleExpiredInvites(trx, batchId);
      const batch = await trx
        .selectFrom('discordInviteBatches')
        .selectAll()
        .where('id', '=', batchId)
        .executeTakeFirst();
      if (!batch) {
        return;
      }
      const { claimed } = await trx
        .selectFrom('userAllowlist')
        .select((eb) => eb.fn.countAll<number>().as('claimed'))
        .where('batchId', '=', batchId)
        .executeTakeFirstOrThrow();
      return { ...batch, remaining: Math.max(0, batch.maxClaims - Number(claimed)) };
    });
  }

  private recycleExpiredInvites(db: Kysely<DB>, batchId: string) {
    if (!env.DISCORD_INVITE_RECYCLING_ENABLED) {
      return;
    }
    return db
      .deleteFrom('userAllowlist')
      .where('batchId', '=', batchId)
      .where('inviteUsed', '=', false)
      .where((eb) =>
        eb.not(
          eb.exists(
            eb
              .selectFrom('discordLinkRequests')
              .select('id')
              .whereRef('allowlistId', '=', 'userAllowlist.id')
              .where('expiresAt', '>', sql<Date>`clock_timestamp()`),
          ),
        ),
      )
      .where((eb) =>
        eb.not(
          eb.exists(
            eb
              .selectFrom('discordLinks')
              .select('id')
              .whereRef('discordLinks.discordUserId', '=', 'userAllowlist.discordUserId'),
          ),
        ),
      )
      .execute();
  }

  createTicket(ticket: Insertable<DiscordTicketTable>) {
    return inTransaction(this.db, async (trx) => {
      await trx
        .insertInto('discordTickets')
        .values(ticket)
        .onConflict((oc) => oc.column('threadId').doNothing())
        .execute();
      return trx
        .selectFrom('discordTickets')
        .selectAll()
        .where('threadId', '=', ticket.threadId)
        .executeTakeFirstOrThrow();
    });
  }

  getTicketByThread(threadId: string) {
    return this.db
      .selectFrom('discordTickets')
      .selectAll()
      .where((eb) => eb.or([eb('threadId', '=', threadId), eb('staffThreadId', '=', threadId)]))
      .executeTakeFirst();
  }

  getTicketByFreshdeskId(freshdeskTicketId: string) {
    return this.db
      .selectFrom('discordTickets')
      .selectAll()
      .where('freshdeskTicketId', '=', freshdeskTicketId)
      .executeTakeFirst();
  }

  listOpenTickets() {
    return this.db
      .selectFrom('discordTickets')
      .selectAll()
      .where('closedAt', 'is', null)
      .orderBy('createdAt', 'asc')
      .execute();
  }

  async updateTicket(id: string, updates: Updateable<DiscordTicketTable>): Promise<boolean> {
    const updated = await this.db
      .updateTable('discordTickets')
      .set(updates)
      .where('id', '=', sql<string>`${id}::uuid`)
      .returning('id')
      .executeTakeFirst();
    return updated !== undefined;
  }

  getUserSummary(userId: string) {
    return this.db
      .selectFrom('users')
      .where('users.id', '=', userId)
      .select((eb) => [
        'users.id',
        'users.name',
        'users.email',
        'users.createdAt',
        eb
          .selectFrom('connections')
          .select((inner) => inner.fn.countAll<number>().as('count'))
          .whereRef('connections.userId', '=', 'users.id')
          .as('connectionCount'),
        eb
          .selectFrom('repositories')
          .select((inner) => inner.fn.countAll<number>().as('count'))
          .whereRef('repositories.userId', '=', 'users.id')
          .as('repositoryCount'),
        eb
          .selectFrom('connections')
          .select((inner) => inner.fn.max('connections.lastSeenAt').as('max'))
          .whereRef('connections.userId', '=', 'users.id')
          .as('lastSeenAt'),
      ])
      .executeTakeFirst();
  }
}
