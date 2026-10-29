import { Injectable } from '@nestjs/common';
import { Insertable, Kysely } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from '../schema/index.js';
import { RepositoryPathTable } from '../schema/tables/repositoryPath.table.js';

@Injectable()
export class RepositoryPathRepository {
  constructor(@InjectKysely('orchestrator') private db: Kysely<DB>) {}

  create(entry: Insertable<RepositoryPathTable>) {
    return this.db.insertInto('futo_backups_repository_path').values(entry).returningAll().executeTakeFirstOrThrow();
  }

  async get(id: string) {
    const result = await this.db.selectFrom('futo_backups_repository_path').select('path').where('id', '=', id).execute();
    return result.map(({ path }) => path);
  }

  getAll() {
    return this.db.selectFrom('futo_backups_repository_path').selectAll().execute();
  }

  delete(id: string, path: string) {
    return this.db
      .deleteFrom('futo_backups_repository_path')
      .where('id', '=', id)
      .where('path', '=', path)
      .executeTakeFirstOrThrow();
  }
}
