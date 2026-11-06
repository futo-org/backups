import { registerEnum } from '@immich/sql-tools';
import { ConfigurationKey, JobName, JobStatus, TaskStatus } from '../enum.js';

export const job_name_enum = registerEnum({
  name: 'futo_backups_job_name_enum',
  values: Object.values(JobName),
});

export const job_status_enum = registerEnum({
  name: 'futo_backups_job_status_enum',
  values: Object.values(JobStatus),
});

export const configuration_key_enum = registerEnum({
  name: 'futo_backups_configuration_key_enum',
  values: Object.values(ConfigurationKey),
});

export const last_backup_status_enum = registerEnum({
  name: 'futo_backups_last_backup_status_enum',
  values: Object.values(TaskStatus), // TODO: replace with jobstatus?
});
