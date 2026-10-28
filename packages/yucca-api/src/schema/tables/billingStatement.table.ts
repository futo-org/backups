import { Column, ForeignKeyColumn, type Generated, Table } from '@immich/sql-tools';
import { UserTable } from './user.table.js';

@Table({ name: 'billingStatements' })
export class BillingStatementTable {
  @Column({ primary: true, type: 'text' })
  orderId!: string;

  @ForeignKeyColumn(() => UserTable, { onUpdate: 'CASCADE', onDelete: 'CASCADE', index: true })
  userId!: string;

  @Column({ type: 'text' })
  billingReason!: string;

  @Column({ type: 'timestamp with time zone', nullable: true })
  periodStart!: Date | null;

  @Column({ type: 'timestamp with time zone', nullable: true })
  periodEnd!: Date | null;

  @Column({ type: 'double precision' })
  gigabyteMonthsUsed!: number;

  @Column({ type: 'integer' })
  amountCents!: number;

  @Column({ type: 'text' })
  currency!: string;

  @Column({ type: 'jsonb' })
  usageIds!: string[];

  @Column({ type: 'jsonb' })
  raw!: Record<string, unknown>;

  @Column({ type: 'timestamp with time zone', default: () => 'now()' })
  createdAt!: Generated<Date>;
}
