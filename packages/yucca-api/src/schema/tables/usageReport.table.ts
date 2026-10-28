import { Column, ForeignKeyColumn, type Generated, Table } from '@immich/sql-tools';
import { UserTable } from './user.table.js';

/** One repository's share of a report: what FUTO Pay is told alongside the total. */
export type UsageReportRepository = {
  repository_id: string;
  name: string | null;
  megabyte_months: number;
};

@Table({ name: 'usageReports' })
export class UsageReportTable {
  @Column({ primary: true, type: 'uuid', default: () => 'gen_random_uuid()' })
  id!: Generated<string>;

  @ForeignKeyColumn(() => UserTable, { onUpdate: 'CASCADE', onDelete: 'CASCADE', index: true })
  userId!: string;

  @Column({ type: 'timestamp with time zone' })
  periodStart!: Date;

  @Column({ type: 'timestamp with time zone' })
  periodEnd!: Date;

  @Column({ type: 'double precision' })
  megabyteMonths!: number;

  // The per-repository split of megabyteMonths, sent to FUTO Pay with the
  // report so Pay can name the customer's repositories (it never sees them
  // otherwise: usage is reported per user)
  @Column({ type: 'jsonb', nullable: true })
  repositories!: UsageReportRepository[] | null;

  @Column({ type: 'text', default: 'pending' })
  status!: Generated<string>;

  @Column({ type: 'integer', default: () => '0' })
  attempts!: Generated<number>;

  @Column({ type: 'text', nullable: true })
  lastError!: string | null;

  @Column({ type: 'jsonb', nullable: true })
  response!: Record<string, unknown> | null;

  @Column({ type: 'timestamp with time zone', default: () => 'now()' })
  createdAt!: Generated<Date>;

  @Column({ type: 'timestamp with time zone', nullable: true })
  sentAt!: Date | null;
}
