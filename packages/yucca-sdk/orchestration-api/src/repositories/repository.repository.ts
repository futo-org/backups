import { Injectable } from '@nestjs/common';
import { Kysely, Updateable } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from '../schema/index.js';
import { RepositoryTable } from '../schema/tables/repository.table.js';
import { RetentionPolicy } from '../utils/restic.js';

type RepositoryRow = {
  id: string;
  remoteId: string;
  backendId: string;
  retentionPolicy: RetentionPolicy | null;
  siteCode: string | null;
  storageClusterCode: string | null;
};

@Injectable()
export class RepositoryRepository {
  constructor(@InjectKysely('orchestrator') private db: Kysely<DB>) {}

  async create(repository: RepositoryRow) {
    await this.db
      .insertInto('futo_backups_repositories')
      .values({
        id: repository.id,
        remoteId: repository.remoteId,
        backendId: repository.backendId,
        retentionPolicy: repository.retentionPolicy === null ? null : JSON.stringify(repository.retentionPolicy),
        siteCode: repository.siteCode,
        storageClusterCode: repository.storageClusterCode,
      })
      .returningAll()
      .executeTakeFirstOrThrow();

    return repository;
  }

  async update(id: string, patch: Partial<Omit<RepositoryRow, 'id'>>) {
    const { retentionPolicy, ...rest } = patch;
    const set: Updateable<RepositoryTable> = { ...rest };
    if ('retentionPolicy' in patch) {
      set.retentionPolicy = retentionPolicy === null ? null : JSON.stringify(retentionPolicy);
    }

    await this.db.updateTable('futo_backups_repositories').set(set).where('id', '=', id).execute();
  }

  async get(id: string): Promise<RepositoryRow | undefined> {
    const row = await this.db
      .selectFrom('futo_backups_repositories')
      .selectAll('futo_backups_repositories')
      .where('id', '=', id)
      .executeTakeFirst();

    if (row) {
      return {
        id: row.id,
        remoteId: row.remoteId,
        backendId: row.backendId,
        retentionPolicy: row.retentionPolicy === null ? null : (JSON.parse(row.retentionPolicy) as RetentionPolicy),
        siteCode: row.siteCode,
        storageClusterCode: row.storageClusterCode,
      };
    }
  }

  async getAll(): Promise<RepositoryRow[]> {
    const rows = await this.db.selectFrom('futo_backups_repositories').selectAll('futo_backups_repositories').execute();
    return rows.map((row) => ({
      id: row.id,
      remoteId: row.remoteId,
      backendId: row.backendId,
      retentionPolicy: row.retentionPolicy === null ? null : (JSON.parse(row.retentionPolicy) as RetentionPolicy),
      siteCode: row.siteCode,
      storageClusterCode: row.storageClusterCode,
    }));
  }

  async delete(id: string) {
    await this.db.deleteFrom('futo_backups_local_metrics').where('repositoryId', '=', id).execute();
    await this.db.deleteFrom('futo_backups_repository_path').where('repositoryId', '=', id).execute();
    await this.db.deleteFrom('futo_backups_repository_schedule').where('repositoryId', '=', id).execute();
    await this.db.deleteFrom('futo_backups_jobs').where('repositoryId', '=', id).execute();
    await this.db.deleteFrom('futo_backups_repositories').where('id', '=', id).execute();
  }
}
