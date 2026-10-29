import { Injectable } from '@nestjs/common';
import { Kysely, Updateable } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { RepositoryMetricsDto } from '../dto/repository.dto.js';
import { DB } from '../schema/index.js';
import { RepositoryLocalMetricsTable } from '../schema/tables/repositoryLocalMetrics.table.js';

@Injectable()
export class RepositoryLocalMetricsRepository {
  constructor(@InjectKysely('orchestrator') private db: Kysely<DB>) {}

  async save(repositoryId: string, metrics: Updateable<RepositoryLocalMetricsTable>) {
    return await this.db
      .insertInto('futo_backups_local_metrics')
      .values({
        repositoryId,
        sizeBytes: 0,
        ...metrics,
      })
      .onConflict((oc) => oc.doUpdateSet(metrics))
      .returningAll()
      .executeTakeFirstOrThrow();
  }

  async get(repositoryId: string): Promise<RepositoryMetricsDto> {
    return (
      (await this.db
        .selectFrom('futo_backups_local_metrics')
        .selectAll('futo_backups_local_metrics')
        .where('repositoryId', '=', repositoryId)
        .executeTakeFirst()) ?? {
        sizeBytes: 0,
      }
    );
  }

  getAll() {
    return this.db.selectFrom('futo_backups_local_metrics').selectAll('futo_backups_local_metrics').execute();
  }
}
