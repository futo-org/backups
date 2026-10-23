import { Injectable } from '@nestjs/common';
import { Kysely } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { BackupStatus } from 'src/enum.js';
import { DB } from 'src/schema/index.js';

@Injectable()
export class BetaInvitesRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  async getBackedUpAccountCount() {
    const { count } = await this.db
      .selectFrom('users')
      .select((eb) => eb.fn.countAll<string>().as('count'))
      // During beta, non-FUTO accounts are assumed to have been invited.
      .where((eb) => eb.fn<string>('lower', ['users.email']), 'not like', '%@futo.org')
      .where((eb) => eb.fn<string>('lower', ['users.email']), 'not like', '%@futo.tech')
      .where((eb) =>
        eb.exists(
          eb
            .selectFrom('repositories')
            .innerJoin('repositoryMetricsHistory', 'repositoryMetricsHistory.repositoryId', 'repositories.id')
            .select('repositories.id')
            .whereRef('repositories.userId', '=', 'users.id')
            .where('repositoryMetricsHistory.backupStatus', '=', BackupStatus.Complete),
        ),
      )
      .executeTakeFirstOrThrow();

    return Number(count);
  }
}
