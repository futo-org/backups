import { ForeignKeyColumn, PrimaryColumn, Table } from '@immich/sql-tools';
import { RepositoryTable } from './repository.table.js';

@Table({ name: 'futo_backups_repository_path' })
export class RepositoryPathTable {
  @ForeignKeyColumn(() => RepositoryTable, { primary: true, onDelete: 'CASCADE', onUpdate: 'CASCADE' })
  repositoryId!: string;

  @PrimaryColumn({ type: 'text' })
  path!: string;
}
