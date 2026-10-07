import { Column, ForeignKeyColumn, Table } from '@immich/sql-tools';
import { BackupStatus } from 'src/enum.js';
import { backup_status_enum } from '../enums.js';
import { RepositoryTable } from './repository.table.js';

@Table({ name: 'repositoryMetrics' })
export class RepositoryMetricsTable {
  @ForeignKeyColumn(() => RepositoryTable, { primary: true, onUpdate: 'CASCADE', onDelete: 'CASCADE' })
  id!: string;

  @Column({ type: 'bigint' })
  sizeBytes!: number;

  @Column({ type: 'timestamp with time zone', nullable: true })
  lastStarted?: Date;

  @Column({ type: 'timestamp with time zone', nullable: true })
  lastBackup?: Date;

  @Column({ type: 'enum', enum: backup_status_enum, nullable: true })
  lastBackupStatus?: BackupStatus;

  @Column({ type: 'integer', nullable: true })
  lastBackupDuration?: number;
}
