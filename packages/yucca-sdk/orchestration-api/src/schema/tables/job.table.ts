import { JobName, JobStatus } from '../../enum.js';

export class JobTable {
  id!: string;
  name!: JobName;
  data!: string;
  repositoryId!: string;

  status!: JobStatus;
  outcome?: string;
  logFilePath!: string;

  queuedAt!: string;
  start?: string;
  end?: string;
}
