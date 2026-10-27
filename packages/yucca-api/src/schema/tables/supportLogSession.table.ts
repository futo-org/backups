import { Column, ForeignKeyColumn, type Generated, Table } from '@immich/sql-tools';
import { ConnectionTable } from './connection.table.js';
import { UserTable } from './user.table.js';

@Table({ name: 'supportLogSessions' })
export class SupportLogSessionTable {
  @Column({ primary: true, type: 'uuid', default: () => 'gen_random_uuid()' })
  id!: Generated<string>;

  @ForeignKeyColumn(() => UserTable, { onUpdate: 'CASCADE', onDelete: 'CASCADE', index: true })
  userId!: string;

  @ForeignKeyColumn(() => ConnectionTable, { onUpdate: 'CASCADE', onDelete: 'SET NULL', nullable: true, index: false })
  connectionId!: string | null;

  @Column()
  jobId!: string;

  @Column()
  jobName!: string;

  @Column({ type: 'boolean' })
  includesPaths!: boolean;

  @Column({ nullable: true })
  clientVersion!: string | null;

  @Column({ type: 'bigint', default: () => '0' })
  lineCount!: Generated<number>;

  @Column({ type: 'bigint', default: () => '0' })
  byteCount!: Generated<number>;

  @Column({ type: 'bigint', default: () => '0' })
  batchCount!: Generated<number>;

  @Column({ type: 'bigint', default: () => '0' })
  droppedLineCount!: Generated<number>;

  @Column({ type: 'timestamp with time zone', default: () => 'now()' })
  createdAt!: Generated<Date>;

  @Column({ type: 'timestamp with time zone', nullable: true })
  lastBatchAt!: Date | null;

  @Column({ type: 'timestamp with time zone', nullable: true })
  finishedAt!: Date | null;
}
