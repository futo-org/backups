import { Injectable } from '@nestjs/common';
import { Insertable, Kysely, Updateable } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from '../schema/index.js';
import { RepositoryTable } from '../schema/tables/repository.table.js';

@Injectable()
export class RepositoryRepository {
  constructor(@InjectKysely('orchestrator') private db: Kysely<DB>) {}

  create(repository: Insertable<RepositoryTable>) {
    return this.db.insertInto('futo_backups_repositories').values(repository).returningAll().executeTakeFirstOrThrow();
  }

  async update(id: string, patch: Updateable<RepositoryTable>) {
    await this.db.updateTable('futo_backups_repositories').set(patch).where('id', '=', id).execute();
  }

  get(id: string) {
    return this.db.selectFrom('futo_backups_repositories').selectAll().where('id', '=', id).executeTakeFirst();
  }

  getAll() {
    return this.db.selectFrom('futo_backups_repositories').selectAll().execute();
  }

  async delete(id: string) {
    await this.db.transaction().execute(async (tx) => {
      await tx.deleteFrom('futo_backups_jobs').where('repositoryId', '=', id).execute();
      await tx.deleteFrom('futo_backups_repositories').where('id', '=', id).execute();
    });
  }
}
