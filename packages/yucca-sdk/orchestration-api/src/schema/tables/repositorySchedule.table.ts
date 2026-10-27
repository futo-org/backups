import { ForeignKeyColumn, Table } from '@immich/sql-tools';
import { RepositoryTable } from './repository.table.js';
import { ScheduleTable } from './schedule.table.js';

@Table({ name: 'futo_backups_repository_schedule' })
export class RepositoryScheduleTable {
  @ForeignKeyColumn(() => ScheduleTable, { primary: true, onDelete: 'CASCADE', onUpdate: 'CASCADE' })
  scheduleId!: string;

  @ForeignKeyColumn(() => RepositoryTable, { primary: true, onDelete: 'CASCADE', onUpdate: 'CASCADE' })
  repositoryId!: string;
}
