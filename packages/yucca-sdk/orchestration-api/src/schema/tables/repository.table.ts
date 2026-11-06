import { Column, ForeignKeyColumn, type Generated, PrimaryColumn, Table } from '@immich/sql-tools';
import type { RetentionPolicy } from '../../utils/restic.js';
import { BackendTable } from './backend.table.js';

@Table({ name: 'futo_backups_repositories' })
export class RepositoryTable {
  @PrimaryColumn({ type: 'uuid', default: () => 'gen_random_uuid()' })
  id!: Generated<string>;

  @Column({ type: 'text' })
  remoteId!: string;

  @ForeignKeyColumn(() => BackendTable, { onDelete: 'RESTRICT', onUpdate: 'CASCADE' })
  backendId!: string;

  @Column({ type: 'jsonb', nullable: true })
  retentionPolicy!: RetentionPolicy | null;

  @Column({ type: 'text', nullable: true })
  siteCode!: string | null;

  @Column({ type: 'text', nullable: true })
  storageClusterCode!: string | null;
}
