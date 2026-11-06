import { Column, type Generated, PrimaryColumn, Table } from '@immich/sql-tools';
import { BackendType } from '../../enum.js';

export type BackendConfiguration =
  | {
      /**
       * Yucca backup backend
       *
       * * Discovers repositories by API
       * * Repository ID used in API
       */
      type: BackendType.Yucca;
      url?: string;
      accessToken: string;
      userId?: string;
    }
  | {
      /**
       * Local backup backend
       *
       * * Discovers repositories by folder listing
       * * Repository ID corresponds to `${path}/${id}`
       */
      type: BackendType.Local;
      path: string;
    }
  | {
      /**
       * S3 backup backend
       *
       * * Discovers repositories by ListBuckets
       * * Repository ID corresponds to bucket ID
       */
      type: BackendType.S3;
      endpoint: string;
      region: string;
      accessKeyId: string;
      secretAccessKey: string;
    };

@Table({ name: 'futo_backups_backends' })
export class BackendTable {
  @PrimaryColumn({ type: 'uuid', default: () => 'gen_random_uuid()' })
  id!: Generated<string>;

  @Column({ type: 'jsonb' })
  configuration!: BackendConfiguration;
}
