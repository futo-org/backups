import { Injectable } from '@nestjs/common';
import { Insertable, Kysely, sql, Updateable } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from '../schema/index.js';
import { ScheduleTable } from '../schema/tables/schedule.table.js';

@Injectable()
export class ScheduleRepository {
  constructor(@InjectKysely('orchestrator') private db: Kysely<DB>) {}

  create(schedule: Insertable<ScheduleTable>) {
    return this.db.insertInto('futo_backups_schedule').values(schedule).returningAll().executeTakeFirstOrThrow();
  }

  async get(id: string) {
    const schedule = await this.selectSchedules().where('id', '=', id).executeTakeFirst();

    return (
      schedule && {
        ...schedule,
        lastRun: schedule.lastRun?.toISOString(),
        lastFinished: schedule.lastFinished?.toISOString(),
      }
    );
  }

  async getAll() {
    const schedules = await this.selectSchedules().execute();

    return schedules.map((schedule) => ({
      ...schedule,
      lastRun: schedule.lastRun?.toISOString(),
      lastFinished: schedule.lastFinished?.toISOString(),
    }));
  }

  private selectSchedules() {
    return this.db
      .selectFrom('futo_backups_schedule')
      .select(['id', 'name', 'paused', 'cron', 'lastRun', 'lastFinished'])
      .select((eb) =>
        eb
          .fn<string[]>('array', [
            eb
              .selectFrom('futo_backups_repository_schedule')
              .select('repositoryId')
              .whereRef('scheduleId', '=', 'futo_backups_schedule.id')
              .orderBy(sql`array_position(futo_backups_schedule.ordering, "repositoryId")`),
          ])
          .as('repositories'),
      );
  }

  async getRepositoryIds(id: string) {
    const repositorySchedules = await this.db
      .selectFrom('futo_backups_repository_schedule')
      .selectAll('futo_backups_repository_schedule')
      .where('scheduleId', '=', id)
      .execute();

    return repositorySchedules.map(({ repositoryId }) => repositoryId);
  }

  updateSchedule(id: string, schedule: Updateable<ScheduleTable>) {
    return this.db
      .updateTable('futo_backups_schedule')
      .where('id', '=', id)
      .set(schedule)
      .returningAll()
      .executeTakeFirst();
  }

  removeSchedule(id: string) {
    return this.db.deleteFrom('futo_backups_schedule').where('id', '=', id).execute();
  }

  addRepositoryToSchedule(scheduleId: string, repositoryId: string) {
    return this.db
      .insertInto('futo_backups_repository_schedule')
      .values({
        repositoryId,
        scheduleId,
      })
      .execute();
  }

  removeRepositoryFromSchedule(scheduleId: string, repositoryId: string) {
    return this.db
      .deleteFrom('futo_backups_repository_schedule')
      .where('scheduleId', '=', scheduleId)
      .where('repositoryId', '=', repositoryId)
      .execute();
  }
}
