import { Injectable } from '@nestjs/common';
import { Kysely } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from '../schema/index.js';
import { ImmichRepositoryConfig } from '../schema/tables/repositoryIntegrationImmich.table.js';

@Injectable()
export class RepositoryIntegrationImmichRepository {
  constructor(@InjectKysely('orchestrator') private db: Kysely<DB>) {}

  async get() {
    const integration = await this.db
      .selectFrom('futo_backups_integrations_immich_config')
      .selectAll()
      .executeTakeFirst();
    if (!integration) {
      return;
    }

    return {
      id: integration.repositoryId,
      scheduleId: integration.scheduleId,
      configuration: integration.configuration,
    };
  }

  async upsert(repositoryId: string, scheduleId: string, configuration: ImmichRepositoryConfig) {
    await this.db.transaction().execute(async (tx) => {
      await tx
        .deleteFrom('futo_backups_integrations_immich_config')
        .where('repositoryId', '!=', repositoryId)
        .execute();

      await tx
        .insertInto('futo_backups_integrations_immich_config')
        .values({
          repositoryId,
          scheduleId,
          configuration,
        })
        .onConflict((oc) => oc.column('repositoryId').doUpdateSet({ configuration, scheduleId }))
        .returningAll()
        .executeTakeFirstOrThrow();
    });
  }

  async delete() {
    await this.db.deleteFrom('futo_backups_integrations_immich_config').execute();
  }
}
