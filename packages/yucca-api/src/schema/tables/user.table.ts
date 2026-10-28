import { Column, type Generated, Table } from '@immich/sql-tools';

export type BillingState = {
  state: string;
  polar_status?: string | null;
  subscription_id?: string | null;
  phase?: string | null;
  current_period_end?: string | null;
  ends_at?: string | null;
  reason?: string | null;
  credit_gb_months?: number;
  credit_used_gb_months?: number;
  credit_remaining_gb_months?: number;
  forwarded_gb_months?: number;
  current_period_start?: string | null;
  period_gb_months?: number;
  // Per UTC day, what the Billing page draws once the credit is spent
  period_usage?: { date: string; gb_months: number }[];
  pending_gb_months?: number;
  pending_amount_cents?: number;
  currency?: string;
  rate_cents_per_gb_month?: number;
  starter_price_cents?: number;
  starter_credit_cents?: number;
};

@Table({ name: 'users' })
export class UserTable {
  @Column({ primary: true, type: 'uuid', default: () => 'gen_random_uuid()' })
  id!: Generated<string>;

  @Column({ index: true, unique: true })
  sub!: string;

  @Column()
  name!: string;

  @Column({ unique: true })
  email!: string;

  @Column({ type: 'boolean', default: () => 'false' })
  disabled!: Generated<boolean>;

  @Column({ type: 'timestamp with time zone', default: () => 'now()' })
  createdAt!: Generated<Date>;

  @Column({ type: 'text', default: 'new' })
  billingStatus!: Generated<string>;

  @Column({ type: 'jsonb', nullable: true })
  billingState!: BillingState | null;

  @Column({ type: 'timestamp with time zone', nullable: true })
  billingUpdatedAt!: Date | null;
}
