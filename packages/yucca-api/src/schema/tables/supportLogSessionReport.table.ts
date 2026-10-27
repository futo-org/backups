import { Column, ForeignKeyColumn, type Generated, Table } from '@immich/sql-tools';
import { SupportLogSessionTable } from './supportLogSession.table.js';

@Table({ name: 'supportLogSessionReports' })
export class SupportLogSessionReportTable {
  @Column({ primary: true, type: 'uuid' })
  id!: string;

  @ForeignKeyColumn(() => SupportLogSessionTable, { onUpdate: 'CASCADE', onDelete: 'CASCADE', index: true })
  sessionId!: string;

  @Column({ type: 'timestamp with time zone', default: () => 'now()' })
  createdAt!: Generated<Date>;
}
