import { JobName, JobStatus } from '../../enum.js';

export class JobTable {
  id!: string;
  name!: JobName;
  data!: string;
  repositoryId!: string;

  status!: JobStatus;
  error?: string;

  queuedAt!: string;
  start?: string;
  end?: string;
}
