import { Injectable } from '@nestjs/common';
import { ExpressionBuilder, Insertable, Kysely, Updateable } from 'kysely';
import { jsonBuildObject } from 'kysely/helpers/postgres';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from 'src/schema/index.js';
import { AuditLogTable } from 'src/schema/tables/auditLog.table.js';
import { RepositoryTable } from 'src/schema/tables/repository.table.js';
import { z } from 'zod';

type RepositoryMetricsJson = {
  sizeBytes: number;
  lastBackup: Date | null;
  lastSuccessfulBackup: Date | null;
  lastBackupDuration?: number;
};

type RepositoryMeterJson = {
  sizeBytes: number;
  objectCount: number;
  lastUpdated: Date | null;
};

export const metricsJson = (eb: ExpressionBuilder<DB, 'repositories' | 'repositoryMetrics'>) =>
  jsonBuildObject({
    sizeBytes: eb.fn.coalesce('repositoryMetrics.sizeBytes', eb.val(0)),
    lastStarted: eb.ref('repositoryMetrics.lastStarted'),
    lastBackup: eb.ref('repositoryMetrics.lastBackup'),
    lastBackupStatus: eb.ref('repositoryMetrics.lastBackupStatus'),
    lastBackupDuration: eb.ref('repositoryMetrics.lastBackupDuration'),
  })
    .$castTo<RepositoryMetricsJson>()
    .as('metrics');

export const meterJson = (eb: ExpressionBuilder<DB, 'repositories' | 'repositoryMeter'>) =>
  jsonBuildObject({
    sizeBytes: eb.fn.coalesce('repositoryMeter.sizeBytes', eb.val(0)),
    objectCount: eb.fn.coalesce('repositoryMeter.objectCount', eb.val(0)),
    lastUpdated: eb.ref('repositoryMeter.timestamp'),
  })
    .$castTo<RepositoryMeterJson>()
    .as('meter');

@Injectable()
export class RepositoryRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  async create(repository: Insertable<RepositoryTable>) {
    const row = await this.db.insertInto('repositories').values(repository).returningAll().executeTakeFirstOrThrow();
    return this.get(row.id);
  }

  private select() {
    return this.db
      .selectFrom('repositories')
      .innerJoin('connections', 'connections.id', 'repositories.connectionId')
      .leftJoin('repositoryMetrics', 'repositoryMetrics.id', 'repositories.id')
      .leftJoin('repositoryMeter', 'repositoryMeter.repositoryId', 'repositories.id')
      .selectAll('repositories')
      .select('connections.type as connectionType')
      .select(metricsJson)
      .select(meterJson);
  }

  get(id: string) {
    return this.select().where('repositories.id', '=', id).executeTakeFirstOrThrow();
  }

  async find(id: string) {
    // Postgres rejects a malformed uuid outright (a 500); it cannot name a repository, so it is simply not found.
    if (!z.guid().safeParse(id).success) {
      return;
    }

    return this.select().where('repositories.id', '=', id).executeTakeFirst();
  }

  getByUser(userId: string) {
    return this.select().where('repositories.userId', '=', userId).execute();
  }

  async update(id: string, repository: Updateable<RepositoryTable>) {
    await this.db.updateTable('repositories').where('id', '=', id).set(repository).execute();
    return this.get(id);
  }

  async disableWorm(id: string, audit: Insertable<AuditLogTable>) {
    await this.db.transaction().execute(async (trx) => {
      await trx.updateTable('repositories').where('id', '=', id).set({ worm: false }).execute();
      await trx.insertInto('auditLog').values(audit).execute();
    });
  }

  async delete(id: string, audit: Insertable<AuditLogTable>) {
    await this.db.transaction().execute(async (trx) => {
      await trx.insertInto('auditLog').values(audit).execute();
      await trx.deleteFrom('repositories').where('id', '=', id).execute();
    });
  }

  getByIds(ids: string[]) {
    return this.db.selectFrom('repositories').selectAll().where('id', 'in', ids).execute();
  }

  async reparent(ids: string[], connectionId: string) {
    await this.db.updateTable('repositories').set({ connectionId }).where('id', 'in', ids).execute();
  }
}
