import { Column, type Generated, Table } from '@immich/sql-tools';

@Table({ name: 'billingWebhookDeliveries' })
export class BillingWebhookDeliveryTable {
  @Column({ primary: true, type: 'text' })
  id!: string;

  @Column({ type: 'text' })
  event!: string;

  @Column({ type: 'timestamp with time zone', default: () => 'now()' })
  receivedAt!: Generated<Date>;
}
