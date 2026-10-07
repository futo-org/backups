import { TaskStatus } from '../../enum.js';

export class RepositoryLocalMetricsTable {
  id!: string;

  sizeBytes!: number;
  lastBackup?: string;
  lastBackupStatus?: TaskStatus;
  lastBackupDuration?: number;
}
