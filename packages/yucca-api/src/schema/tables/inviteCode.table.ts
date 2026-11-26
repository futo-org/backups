import { Column, type Generated, Table } from '@immich/sql-tools';

@Table({ name: 'inviteCodes' })
export class InviteCodeTable {
  @Column({ primary: true, type: 'uuid', default: () => 'gen_random_uuid()' })
  id!: Generated<string>;

  @Column({ unique: true })
  code!: string;

  @Column({ unique: true })
  name!: string;

  @Column({ type: 'integer', nullable: true })
  maxUses!: number | null;

  @Column({ type: 'timestamp with time zone', nullable: true })
  expiresAt!: Date | null;

  @Column({ type: 'timestamp with time zone', nullable: true })
  revokedAt!: Date | null;

  @Column({ type: 'timestamp with time zone', default: () => 'now()' })
  createdAt!: Generated<Date>;
}
