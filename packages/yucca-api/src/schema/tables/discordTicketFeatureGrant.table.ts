import { Column, ForeignKeyColumn, type Generated, Table, Unique } from '@immich/sql-tools';
import { UserTable } from './user.table.js';

@Table({ name: 'discordTicketFeatureGrants' })
@Unique({ columns: ['threadId', 'userId', 'flag'] })
export class DiscordTicketFeatureGrantTable {
  @Column({ primary: true, type: 'uuid', default: () => 'gen_random_uuid()' })
  id!: Generated<string>;

  @Column()
  threadId!: string;

  @ForeignKeyColumn(() => UserTable, { onUpdate: 'CASCADE', onDelete: 'CASCADE', index: true })
  userId!: string;

  @Column()
  flag!: string;

  @Column({ type: 'timestamp with time zone', default: () => 'now()' })
  createdAt!: Generated<Date>;
}
