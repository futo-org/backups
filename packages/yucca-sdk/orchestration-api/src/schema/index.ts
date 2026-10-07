import { BackendTable } from './tables/backend.table.js';
import { ConfigTable } from './tables/config.table.js';
import { RepositoryTable } from './tables/repository.table.js';
import { RepositoryIntegrationImmichTable } from './tables/repositoryIntegrationImmich.table.js';
import { RepositoryLocalMetricsTable } from './tables/repositoryLocalMetrics.table.js';
import { RepositoryPathTable } from './tables/repositoryPath.table.js';
import { RepositoryScheduleTable } from './tables/repositorySchedule.table.js';
import { RunHistoryTable } from './tables/runHistory.table.js';
import { ScheduleTable } from './tables/schedule.table.js';

export interface DB {
  backends: BackendTable;
  config: ConfigTable;
  repositories: RepositoryTable;
  repositoryIntegrationImmich: RepositoryIntegrationImmichTable;
  repositoryPaths: RepositoryPathTable;
  repositorySchedules: RepositoryScheduleTable;
  repositoryLocalMetrics: RepositoryLocalMetricsTable;
  runHistory: RunHistoryTable;
  schedules: ScheduleTable;
}
