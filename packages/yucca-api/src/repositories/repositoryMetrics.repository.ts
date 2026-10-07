import { Injectable } from '@nestjs/common';
import { Kysely, Updateable } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from 'src/schema/index.js';
import { RepositoryMetricsTable } from 'src/schema/tables/repositoryMetrics.table.js';

@Injectable()
export class RepositoryMetricsRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  save(id: string, metrics: Updateable<RepositoryMetricsTable>) {
    return this.db
      .insertInto('repositoryMetrics')
      .values({ id, sizeBytes: 0, ...metrics })
      .onConflict((oc) => oc.column('id').doUpdateSet(metrics))
      .returningAll()
      .executeTakeFirstOrThrow();
  }

  get(id: string) {
    return this.db
      .selectFrom('repositoryMetrics')
      .selectAll('repositoryMetrics')
      .where('id', '=', id)
      .executeTakeFirst();
  }
}
