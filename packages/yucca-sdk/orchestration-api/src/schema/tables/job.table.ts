import { Column, type Generated, Index, type Int8, PrimaryColumn, Table, type Timestamp } from '@immich/sql-tools';

import type { JobOutcomeDto } from '../../dto/job.dto.js';
import { JobName, JobStatus } from '../../enum.js';
import type { JobItem } from '../../utils/types.js';
import { job_name_enum, job_status_enum } from '../enums.js';

@Table({ name: 'futo_backups_jobs' })
@Index({
  name: 'futo_backups_jobs_status_sequence_idx',
  columns: ['status', 'sequence'],
})
@Index({
  name: 'futo_backups_jobs_repository_history_idx',
  columns: ['repositoryId', 'queuedAt', 'sequence'],
})
@Index({
  name: 'futo_backups_jobs_repository_name_history_idx',
  columns: ['repositoryId', 'name', 'queuedAt', 'sequence'],
})
export class JobTable {
  @PrimaryColumn({ type: 'uuid', default: () => 'gen_random_uuid()' })
  id!: Generated<string>;

  @Column({ type: 'bigint', identity: true, unique: true })
  sequence!: Generated<Int8>;

  @Column({ type: 'enum', enum: job_name_enum })
  name!: JobName;

  @Column({ type: 'jsonb' })
  data!: JobItem['data'];

  @Column({ type: 'text' })
  repositoryId!: string;

  @Column({ type: 'enum', enum: job_status_enum })
  status!: JobStatus;

  @Column({ type: 'jsonb', nullable: true })
  outcome!: JobOutcomeDto | null;

  @Column({ type: 'text' })
  logFilePath!: string;

  @Column({ type: 'timestamp with time zone', default: () => 'now()' })
  queuedAt!: Generated<Timestamp>;

  @Column({ type: 'timestamp with time zone', nullable: true })
  start!: Timestamp | null;

  @Column({ type: 'timestamp with time zone', nullable: true })
  end!: Timestamp | null;
}
