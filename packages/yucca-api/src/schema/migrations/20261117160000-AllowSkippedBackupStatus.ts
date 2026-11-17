import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`ALTER TYPE "backup_status_enum" ADD VALUE 'skipped';`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`UPDATE "repositoryMetricsHistory" SET "backupStatus" = NULL WHERE "backupStatus" = 'skipped';`.execute(db);
  await sql`ALTER TYPE "backup_status_enum" RENAME TO "backup_status_enum_old";`.execute(db);
  await sql`CREATE TYPE "backup_status_enum" AS ENUM ('incomplete','complete','warn','failed','cancelled');`.execute(
    db,
  );
  await sql`ALTER TABLE "repositoryMetrics" ALTER COLUMN "lastBackupStatus" TYPE backup_status_enum USING "lastBackupStatus"::text::backup_status_enum;`.execute(
    db,
  );
  await sql`ALTER TABLE "repositoryMetricsHistory" ALTER COLUMN "backupStatus" TYPE backup_status_enum USING "backupStatus"::text::backup_status_enum;`.execute(
    db,
  );
  await sql`DROP TYPE "backup_status_enum_old";`.execute(db);
}
