import { Injectable } from '@nestjs/common';
import { Insertable, Kysely, Selectable, sql, Updateable } from 'kysely';
import { jsonArrayFrom } from 'kysely/helpers/postgres';
import { InjectKysely } from 'nestjs-kysely';
import { ConnectionRepository } from 'src/repositories/connection.repository.js';
import { DiscordRepository } from 'src/repositories/discord.repository.js';
import { inTransaction } from 'src/repositories/transaction.js';
import { UserAllowlistRepository } from 'src/repositories/userAllowlist.repository.js';
import { DB } from 'src/schema/index.js';
import { UserTable } from 'src/schema/tables/user.table.js';

export type RegistrationRepositories = {
  user: UserRepository;
  allowlist: UserAllowlistRepository;
  connection: ConnectionRepository;
  discord: DiscordRepository;
};

type RegistrationUser = Pick<Selectable<UserTable>, 'id' | 'disabled'>;

@Injectable()
export class UserRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  withRegistration(sub: string, operation: (repositories: RegistrationRepositories) => Promise<RegistrationUser>) {
    return inTransaction(
      this.db,
      async (transaction) => {
        await sql`SELECT pg_advisory_xact_lock(hashtext(${'registration:' + sub}))`.execute(transaction);
        return operation({
          user: new UserRepository(transaction),
          allowlist: new UserAllowlistRepository(transaction),
          connection: new ConnectionRepository(transaction),
          discord: new DiscordRepository(transaction),
        });
      },
      { retryDeadlocks: true },
    );
  }

  create(user: Insertable<UserTable>) {
    return this.db.insertInto('users').values(user).returningAll().executeTakeFirstOrThrow();
  }

  getBySub(sub: string) {
    return this.db.selectFrom('users').select(['id', 'disabled']).where('sub', '=', sub).executeTakeFirst();
  }

  getByEmail(email: string) {
    return this.db.selectFrom('users').select(['id']).where('email', '=', email).executeTakeFirst();
  }

  getByAccessToken(accessToken: string) {
    return this.db
      .selectFrom('sessions')
      .where('accessToken', '=', accessToken)
      .innerJoin('users', 'users.id', 'sessions.userId')
      .leftJoin('connections', 'connections.id', 'sessions.connectionId')
      .where('users.disabled', '=', false)
      .select((eb) => [
        'users.id',
        'users.sub',
        'users.name',
        'users.email',
        'sessions.id as sessionId',
        'sessions.connectionId as connectionId',
        'connections.lastSeenAt as connectionLastSeenAt',
        jsonArrayFrom(
          eb
            .selectFrom('userFeatureFlagOverride')
            .select(['flag', 'value'])
            .whereRef('userFeatureFlagOverride.userId', '=', 'users.id'),
        )
          .$castTo<{ flag: string; value: boolean }[]>()
          .as('featureOverrides'),
      ])
      .executeTakeFirst();
  }

  getFeatureOverrides(userId: string) {
    return this.db
      .selectFrom('userFeatureFlagOverride')
      .select(['flag', 'value'])
      .where('userId', '=', userId)
      .execute();
  }

  update(id: string, user: Updateable<UserTable>) {
    return this.db
      .updateTable('users')
      .set(user)
      .where('id', '=', sql<string>`${id}::uuid`)
      .returning('id')
      .executeTakeFirst();
  }
}
