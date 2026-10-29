import { Column, ForeignKeyColumn, type Generated, type Int8, Table, type Timestamp } from '@immich/sql-tools';
import { TaskStatus } from '../../enum.js';
import { last_backup_status_enum } from '../enums.js';
import { RepositoryTable } from './repository.table.js';

@Table({ name: 'futo_backups_local_metrics' })
export class RepositoryLocalMetricsTable {
  @ForeignKeyColumn(() => RepositoryTable, { primary: true, onDelete: 'CASCADE', onUpdate: 'CASCADE' })
  repositoryId!: string;

  @Column({ type: 'bigint', default: 0 })
  sizeBytes!: Generated<Int8>;

  @Column({ type: 'timestamp with time zone', nullable: true })
  lastBackup!: Timestamp | null;

  @Column({ type: 'enum', enum: last_backup_status_enum, nullable: true })
  lastBackupStatus!: TaskStatus | null;

  @Column({ type: 'integer', nullable: true })
  lastBackupDuration!: number | null;
}
