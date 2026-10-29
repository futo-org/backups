import { Injectable } from '@nestjs/common';
import { Kysely } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { createBackend } from '../backends/createBackend.js';
import { DB } from '../schema/index.js';
import { BackendConfiguration } from '../schema/tables/backend.table.js';

@Injectable()
export class BackendRepository {
  constructor(@InjectKysely('orchestrator') private db: Kysely<DB>) {}

  async updateBackend(id: string, configuration: BackendConfiguration) {
    return await this.db
      .insertInto('futo_backups_backends')
      .values({ id, configuration })
      .onConflict((oc) => oc.column('id').doUpdateSet({ configuration }))
      .returningAll()
      .executeTakeFirstOrThrow();
  }

  async getBackends() {
    const backends = await this.db.selectFrom('futo_backups_backends').selectAll().execute();
    return backends.map(({ id, configuration }) => ({ id, configuration, backend: createBackend(configuration) }));
  }

  async getBackend(id: string) {
    const backend = await this.db
      .selectFrom('futo_backups_backends')
      .selectAll()
      .where('id', '=', id)
      .executeTakeFirst();

    return backend && { ...backend, backend: createBackend(backend.configuration) };
  }
}
