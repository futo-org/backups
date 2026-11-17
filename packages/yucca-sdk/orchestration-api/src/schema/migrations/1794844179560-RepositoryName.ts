import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`ALTER TABLE "futo_backups_repositories" ADD COLUMN "name" text;`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`ALTER TABLE "futo_backups_repositories" DROP COLUMN "name";`.execute(db);
}
