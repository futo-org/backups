import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`ALTER TYPE "futo_backups_configuration_key_enum" ADD VALUE 'installation-id';`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DELETE FROM "futo_backups_config" WHERE "key" = 'installation-id';`.execute(db);
  await sql`ALTER TYPE "futo_backups_configuration_key_enum" RENAME TO "futo_backups_configuration_key_enum_old";`.execute(
    db,
  );
  await sql`CREATE TYPE "futo_backups_configuration_key_enum" AS ENUM ('encryption-key','onboarded-key','telemetry','skipped-onboarding-extra-config','ignored-immich-database-dump-warning','restic-o-rest-connections','session-secret','state-path','throttle','support-mode','restore-awaiting-continue');`.execute(
    db,
  );
  await sql`ALTER TABLE "futo_backups_config" ALTER COLUMN "key" TYPE futo_backups_configuration_key_enum USING "key"::text::futo_backups_configuration_key_enum;`.execute(
    db,
  );
  await sql`DROP TYPE "futo_backups_configuration_key_enum_old";`.execute(db);
}
