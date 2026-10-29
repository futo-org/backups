import { Column, ForeignKeyColumn, Table } from '@immich/sql-tools';
import { RepositoryTable } from './repository.table.js';
import { ScheduleTable } from './schedule.table.js';

export type ImmichRepositoryConfig = {
  dataFolders: string[];
  backupConfiguration: boolean;
  libraries: string[];
};

@Table({ name: 'futo_backups_integrations_immich_config' })
export class RepositoryIntegrationImmichTable {
  @ForeignKeyColumn(() => RepositoryTable, { primary: true, onDelete: 'CASCADE', onUpdate: 'CASCADE' })
  repositoryId!: string;

  @ForeignKeyColumn(() => ScheduleTable, { onDelete: 'RESTRICT', onUpdate: 'CASCADE' })
  scheduleId!: string;

  @Column({ type: 'jsonb' })
  configuration!: ImmichRepositoryConfig;
}
