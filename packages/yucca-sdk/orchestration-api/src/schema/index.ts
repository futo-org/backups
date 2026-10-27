import { Database } from '@immich/sql-tools';
import { configuration_key_enum, job_name_enum, job_status_enum, last_backup_status_enum } from './enums.js';
import { BackendTable } from './tables/backend.table.js';
import { ConfigTable } from './tables/config.table.js';
import { JobTable } from './tables/job.table.js';
import { RepositoryTable } from './tables/repository.table.js';
import { RepositoryIntegrationImmichTable } from './tables/repositoryIntegrationImmich.table.js';
import { RepositoryLocalMetricsTable } from './tables/repositoryLocalMetrics.table.js';
import { RepositoryPathTable } from './tables/repositoryPath.table.js';
import { RepositoryScheduleTable } from './tables/repositorySchedule.table.js';
import { ScheduleTable } from './tables/schedule.table.js';

@Database({ name: 'futo_backups' })
export class OrchestrationDatabase {
  tables = [
    BackendTable,
    ConfigTable,
    JobTable,
    RepositoryTable,
    RepositoryIntegrationImmichTable,
    RepositoryPathTable,
    RepositoryScheduleTable,
    RepositoryLocalMetricsTable,
    ScheduleTable,
  ];

  enum = [configuration_key_enum, job_name_enum, job_status_enum, last_backup_status_enum];
}

export type DB = {
  futo_backups_backends: BackendTable;
  futo_backups_config: ConfigTable;
  futo_backups_jobs: JobTable;
  futo_backups_repositories: RepositoryTable;
  futo_backups_integrations_immich_config: RepositoryIntegrationImmichTable;
  futo_backups_repository_path: RepositoryPathTable;
  futo_backups_repository_schedule: RepositoryScheduleTable;
  futo_backups_local_metrics: RepositoryLocalMetricsTable;
  futo_backups_schedule: ScheduleTable;
};
