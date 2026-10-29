import { Generated } from 'kysely';

export type LegacyDB = {
  backends: {
    id: Generated<string>;
    configuration: string;
  };
  config: {
    key: string;
    value: string;
  };
  jobs: {
    id: string;
    name: string;
    data: string;
    repositoryId: string;
    status: string;
    outcome: string | null;
    logFilePath: string;
    queuedAt: string;
    start: string | null;
    end: string | null;
  };
  repositories: {
    id: string;
    remoteId: string;
    backendId: string;
    retentionPolicy: string | null;
    siteCode: string | null;
    storageClusterCode: string | null;
  };
  repositoryIntegrationImmich: {
    id: string;
    scheduleId: string | null;
    configuration: string;
  };
  repositoryPaths: {
    id: string;
    path: string;
  };
  repositorySchedules: {
    schedule: string;
    repository: string;
  };
  repositoryLocalMetrics: {
    id: string;
    sizeBytes: number;
    lastBackup: string | null;
    lastBackupStatus: string | null;
    lastBackupDuration: number | null;
  };
  schedules: {
    id: string;
    name: string;
    paused: number;
    cron: string;
    ordering: string;
    lastRun: string | null;
    lastFinished: string | null;
  };
};
