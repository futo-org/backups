import { Column, ForeignKeyColumn, type Generated, Table } from '@immich/sql-tools';
import { InviteCodeTable } from './inviteCode.table.js';
import { UserTable } from './user.table.js';

@Table({ name: 'inviteCodeRedemptions' })
export class InviteCodeRedemptionTable {
  @Column({ primary: true, type: 'uuid', default: () => 'gen_random_uuid()' })
  id!: Generated<string>;

  @ForeignKeyColumn(() => InviteCodeTable, { onUpdate: 'CASCADE', onDelete: 'CASCADE', index: true })
  inviteCodeId!: string;

  @ForeignKeyColumn(() => UserTable, { onUpdate: 'CASCADE', onDelete: 'CASCADE', unique: true, index: false })
  userId!: string;

  @Column({ type: 'timestamp with time zone', default: () => 'now()' })
  createdAt!: Generated<Date>;
}
