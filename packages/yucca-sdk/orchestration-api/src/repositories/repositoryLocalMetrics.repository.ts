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
    const row = await this.db
      .insertInto('futo_backups_local_metrics')
      .values({
        repositoryId,
        ...metrics,
      })
      .onConflict((oc) => oc.column('repositoryId').doUpdateSet(metrics))
      .returning(['sizeBytes', 'lastBackup', 'lastBackupStatus', 'lastBackupDuration'])
      .executeTakeFirstOrThrow();

    return { ...row, lastBackup: row.lastBackup?.toISOString() };
  }

  async get(repositoryId: string): Promise<RepositoryMetricsDto> {
    const row = await this.db
      .selectFrom('futo_backups_local_metrics')
      .select(['sizeBytes', 'lastBackup', 'lastBackupStatus', 'lastBackupDuration'])
      .where('repositoryId', '=', repositoryId)
      .executeTakeFirst();

    return row ? { ...row, lastBackup: row.lastBackup?.toISOString() } : { sizeBytes: 0 };
  }

  async getAll() {
    const rows = await this.db
      .selectFrom('futo_backups_local_metrics')
      .select(['repositoryId', 'sizeBytes', 'lastBackup', 'lastBackupStatus', 'lastBackupDuration'])
      .execute();

    return new Map(
      rows.map(({ repositoryId, lastBackup, ...metrics }) => [
        repositoryId,
        { ...metrics, lastBackup: lastBackup?.toISOString() },
      ]),
    );
  }
}
