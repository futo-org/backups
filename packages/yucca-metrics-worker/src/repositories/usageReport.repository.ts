import { Injectable } from '@nestjs/common';
import { Kysely, sql } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from 'src/schema/index.js';

const ADMIN_SERVICE_SUB = 'yucca-admin-service';

export type MeterSample = {
  repositoryId: string;
  repositoryName?: string;
  connectionType: string;
  timestamp: Date;
  sizeBytes: number;
  objectCount: number;
};

export type UsageReportShare = {
  repository_id: string;
  name: string | null;
  megabyte_months: number;
};

export type UsageReportRow = {
  id: string;
  userId: string;
  sub: string;
  email: string;
  periodStart: Date;
  periodEnd: Date;
  megabyteMonths: number;
  repositories: UsageReportShare[] | null;
  status: string;
  attempts: number;
};

@Injectable()
export class UsageReportRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  listBillableUsers() {
    return this.db
      .selectFrom('users')
      .select(['id', 'sub', 'email'])
      .where('disabled', '=', false)
      .where('sub', '!=', ADMIN_SERVICE_SUB)
      .orderBy('id')
      .execute();
  }

  async getSamples(userId: string, periodStart: Date, periodEnd: Date): Promise<MeterSample[]> {
    const carriedIn = await this.db
      .selectFrom('repositoryMeterHistory')
      .innerJoin('repositories', 'repositories.id', 'repositoryMeterHistory.repositoryId')
      .innerJoin('connections', 'connections.id', 'repositories.connectionId')
      .distinctOn('repositoryMeterHistory.repositoryId')
      .select([
        'repositoryMeterHistory.repositoryId',
        'repositories.name as repositoryName',
        'connections.type as connectionType',
        'repositoryMeterHistory.timestamp',
        'repositoryMeterHistory.sizeBytes',
        'repositoryMeterHistory.objectCount',
      ])
      .where('repositories.userId', '=', userId)
      .where('repositoryMeterHistory.timestamp', '<', periodStart)
      .orderBy('repositoryMeterHistory.repositoryId')
      .orderBy('repositoryMeterHistory.timestamp', 'desc')
      .execute();

    const inPeriod = await this.db
      .selectFrom('repositoryMeterHistory')
      .innerJoin('repositories', 'repositories.id', 'repositoryMeterHistory.repositoryId')
      .innerJoin('connections', 'connections.id', 'repositories.connectionId')
      .select([
        'repositoryMeterHistory.repositoryId',
        'repositories.name as repositoryName',
        'connections.type as connectionType',
        'repositoryMeterHistory.timestamp',
        'repositoryMeterHistory.sizeBytes',
        'repositoryMeterHistory.objectCount',
      ])
      .where('repositories.userId', '=', userId)
      .where('repositoryMeterHistory.timestamp', '>=', periodStart)
      .where('repositoryMeterHistory.timestamp', '<', periodEnd)
      .orderBy('repositoryMeterHistory.timestamp')
      .execute();

    return [...carriedIn, ...inPeriod].map((row) => ({
      ...row,
      sizeBytes: Number(row.sizeBytes),
      objectCount: Number(row.objectCount),
    }));
  }

  async create(report: {
    userId: string;
    periodStart: Date;
    periodEnd: Date;
    megabyteMonths: number;
    repositories: UsageReportShare[];
  }) {
    const row = await this.db
      .insertInto('usageReports')
      // postgres.js serializes a parameter whose type is jsonb itself, so the
      // value goes in as is: a JSON string here would be stored double-encoded
      .values({ ...report, repositories: sql<UsageReportShare[]>`${report.repositories}::jsonb` })
      .onConflict((oc) => oc.columns(['userId', 'periodStart']).doNothing())
      .returning('id')
      .executeTakeFirst();
    return row?.id ?? null;
  }

  listPending(limit: number): Promise<UsageReportRow[]> {
    return this.db
      .selectFrom('usageReports')
      .innerJoin('users', 'users.id', 'usageReports.userId')
      .select([
        'usageReports.id',
        'usageReports.userId',
        'users.sub',
        'users.email',
        'usageReports.periodStart',
        'usageReports.periodEnd',
        'usageReports.megabyteMonths',
        'usageReports.repositories',
        'usageReports.status',
        'usageReports.attempts',
      ])
      .where('usageReports.status', '=', 'pending')
      .orderBy('usageReports.periodStart')
      .limit(limit)
      .execute();
  }

  listForPeriod(periodStart: Date) {
    return this.db
      .selectFrom('usageReports')
      .innerJoin('users', 'users.id', 'usageReports.userId')
      .selectAll('usageReports')
      .select(['users.sub', 'users.email'])
      .where('usageReports.periodStart', '=', periodStart)
      .orderBy('usageReports.userId')
      .execute();
  }

  markSettled(id: string, status: string, response: Record<string, unknown>) {
    return this.db
      .updateTable('usageReports')
      .set({
        status,
        response: sql<Record<string, unknown>>`${response}::jsonb`,
        sentAt: new Date(),
        lastError: null,
        attempts: sql`attempts + 1`,
      })
      .where('id', '=', id)
      .execute();
  }

  markFailed(ids: string[], error: string) {
    return this.db
      .updateTable('usageReports')
      .set({ lastError: error.slice(0, 500), attempts: sql`attempts + 1` })
      .where('id', 'in', ids)
      .execute();
  }
}
