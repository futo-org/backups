import { Column, type Generated, PrimaryColumn, Table, type Timestamp } from '@immich/sql-tools';

@Table({ name: 'futo_backups_schedule' })
export class ScheduleTable {
  @PrimaryColumn({ type: 'uuid', default: () => 'gen_random_uuid()' })
  id!: Generated<string>;

  @Column({ type: 'text' })
  name!: string;

  @Column({ type: 'boolean', default: false })
  paused!: Generated<boolean>;

  @Column({ type: 'text' })
  cron!: string;

  @Column({ type: 'uuid', array: true, default: () => "'{}'::uuid[]" })
  ordering!: Generated<string[]>;

  @Column({ type: 'timestamp with time zone', nullable: true })
  lastRun!: Timestamp | null;

  @Column({ type: 'timestamp with time zone', nullable: true })
  lastFinished!: Timestamp | null;
}
