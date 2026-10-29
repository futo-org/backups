import { Injectable } from '@nestjs/common';
import { Insertable, Kysely, Updateable } from 'kysely';
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
    const row = await this.db.selectFrom('futo_backups_schedule').selectAll('futo_backups_schedule').where('id', '=', id).executeTakeFirst();

    if (row) {
      const { ordering, paused, ...schedule } = row;

      const repositorySchedules = await this.db
        .selectFrom('futo_backups_repository_schedule')
        .selectAll('futo_backups_repository_schedule')
        .where('schedule', '=', id)
        .execute();

      return {
        ...schedule,
        paused: !!paused,
        repositories: repositorySchedules
          .filter(({ schedule: scheduleId }) => scheduleId === schedule.id)
          .map(({ repository }) => repository)
          .toSorted((a, b) => ordering.indexOf(a) - ordering.indexOf(b)),
      };
    }
  }

  async getAll() {
    const schedules = await this.db.selectFrom('futo_backups_schedule').selectAll('futo_backups_schedule').execute();
    const repositorySchedules = await this.db
      .selectFrom('futo_backups_repository_schedule')
      .selectAll('futo_backups_repository_schedule')
      .execute();

    return schedules.map(({ ordering, paused, ...schedule }) => ({
      ...schedule,
      paused: !!paused,
      repositories: repositorySchedules
        .filter(({ schedule: scheduleId }) => scheduleId === schedule.id)
        .map(({ repository }) => repository)
        .toSorted((a, b) => ordering.indexOf(a) - ordering.indexOf(b)),
    }));
  }

  async getRepositoryIds(id: string) {
    const repositorySchedules = await this.db
      .selectFrom('futo_backups_repository_schedule')
      .selectAll('futo_backups_repository_schedule')
      .where('schedule', '=', id)
      .execute();

    return repositorySchedules.map(({ repository }) => repository);
  }

  updateSchedule(id: string, schedule: Updateable<ScheduleTable>) {
    return this.db.updateTable('futo_backups_schedule').where('id', '=', id).set(schedule).returningAll().executeTakeFirst();
  }

  removeSchedule(id: string) {
    return this.db.deleteFrom('futo_backups_schedule').where('id', '=', id).execute();
  }

  addRepositoryToSchedule(schedule: string, repository: string) {
    return this.db
      .insertInto('futo_backups_repository_schedule')
      .values({
        repository,
        schedule,
      })
      .execute();
  }

  removeRepositoryFromSchedule(schedule: string, repository: string) {
    return this.db
      .deleteFrom('futo_backups_repository_schedule')
      .where('schedule', '=', schedule)
      .where('repository', '=', repository)
      .execute();
  }
}
