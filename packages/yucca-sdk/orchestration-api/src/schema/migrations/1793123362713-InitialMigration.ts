import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`CREATE TYPE "futo_backups_job_name_enum" AS ENUM ('repository-backup','repository-prune','repository-restore','repository-restore-from-point','repository-snapshot-forget','repository-sync-metrics');`.execute(db);
  await sql`CREATE TYPE "futo_backups_job_status_enum" AS ENUM ('queued','running','complete','warn','failed','cancelled','incomplete');`.execute(db);
  await sql`CREATE TYPE "futo_backups_configuration_key_enum" AS ENUM ('encryption-key','onboarded-key','telemetry','skipped-onboarding-extra-config','ignored-immich-database-dump-warning','restic-o-rest-connections','session-secret','state-path','throttle-bytes-per-sec','throttle-quiet-hours');`.execute(db);
  await sql`CREATE TYPE "futo_backups_last_backup_status_enum" AS ENUM ('incomplete','complete','warn','failed','cancelled');`.execute(db);
  await sql`CREATE TABLE "futo_backups_backends" (
  "id" uuid NOT NULL DEFAULT gen_random_uuid(),
  "configuration" jsonb NOT NULL,
  CONSTRAINT "futo_backups_backends_pkey" PRIMARY KEY ("id")
);`.execute(db);
  await sql`CREATE TABLE "futo_backups_config" (
  "key" futo_backups_configuration_key_enum NOT NULL,
  "value" jsonb NOT NULL,
  CONSTRAINT "futo_backups_config_pkey" PRIMARY KEY ("key")
);`.execute(db);
  await sql`CREATE TABLE "futo_backups_jobs" (
  "id" uuid NOT NULL DEFAULT gen_random_uuid(),
  "sequence" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "name" futo_backups_job_name_enum NOT NULL,
  "data" jsonb NOT NULL,
  "repositoryId" text NOT NULL,
  "status" futo_backups_job_status_enum NOT NULL,
  "outcome" jsonb,
  "logFilePath" text NOT NULL,
  "queuedAt" timestamp with time zone NOT NULL DEFAULT now(),
  "start" timestamp with time zone,
  "end" timestamp with time zone,
  CONSTRAINT "futo_backups_jobs_sequence_uq" UNIQUE ("sequence"),
  CONSTRAINT "futo_backups_jobs_pkey" PRIMARY KEY ("id")
);`.execute(db);
  await sql`CREATE TABLE "futo_backups_repositories" (
  "id" uuid NOT NULL DEFAULT gen_random_uuid(),
  "remoteId" text NOT NULL,
  "backendId" uuid NOT NULL,
  "retentionPolicy" jsonb,
  "siteCode" text,
  "storageClusterCode" text,
  CONSTRAINT "futo_backups_repositories_backendId_fkey" FOREIGN KEY ("backendId") REFERENCES "futo_backups_backends" ("id") ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT "futo_backups_repositories_pkey" PRIMARY KEY ("id")
);`.execute(db);
  await sql`CREATE INDEX "futo_backups_repositories_backendId_idx" ON "futo_backups_repositories" ("backendId");`.execute(db);
  await sql`CREATE TABLE "futo_backups_schedule" (
  "id" uuid NOT NULL DEFAULT gen_random_uuid(),
  "name" text NOT NULL,
  "paused" boolean NOT NULL DEFAULT false,
  "cron" text NOT NULL,
  "ordering" uuid[] NOT NULL DEFAULT '{}'::uuid[],
  "lastRun" timestamp with time zone,
  "lastFinished" timestamp with time zone,
  CONSTRAINT "futo_backups_schedule_pkey" PRIMARY KEY ("id")
);`.execute(db);
  await sql`CREATE TABLE "futo_backups_integrations_immich_config" (
  "id" uuid NOT NULL,
  "scheduleId" uuid NOT NULL,
  "configuration" jsonb NOT NULL,
  CONSTRAINT "futo_backups_integrations_immich_config_id_fkey" FOREIGN KEY ("id") REFERENCES "futo_backups_repositories" ("id") ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT "futo_backups_integrations_immich_config_scheduleId_fkey" FOREIGN KEY ("scheduleId") REFERENCES "futo_backups_schedule" ("id") ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT "futo_backups_integrations_immich_config_pkey" PRIMARY KEY ("id")
);`.execute(db);
  await sql`CREATE INDEX "futo_backups_integrations_immich_config_scheduleId_idx" ON "futo_backups_integrations_immich_config" ("scheduleId");`.execute(db);
  await sql`CREATE TABLE "futo_backups_local_metrics" (
  "id" uuid NOT NULL,
  "sizeBytes" bigint NOT NULL DEFAULT 0,
  "lastBackup" timestamp with time zone,
  "lastBackupStatus" futo_backups_last_backup_status_enum,
  "lastBackupDuration" integer,
  CONSTRAINT "futo_backups_local_metrics_id_fkey" FOREIGN KEY ("id") REFERENCES "futo_backups_repositories" ("id") ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT "futo_backups_local_metrics_pkey" PRIMARY KEY ("id")
);`.execute(db);
  await sql`CREATE TABLE "futo_backups_repository_path" (
  "id" uuid NOT NULL,
  "path" text NOT NULL,
  CONSTRAINT "futo_backups_repository_path_id_fkey" FOREIGN KEY ("id") REFERENCES "futo_backups_repositories" ("id") ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT "futo_backups_repository_path_pkey" PRIMARY KEY ("id", "path")
);`.execute(db);
  await sql`CREATE INDEX "futo_backups_repository_path_id_idx" ON "futo_backups_repository_path" ("id");`.execute(db);
  await sql`CREATE TABLE "futo_backups_repository_schedule" (
  "schedule" uuid NOT NULL,
  "repository" uuid NOT NULL,
  CONSTRAINT "futo_backups_repository_schedule_schedule_fkey" FOREIGN KEY ("schedule") REFERENCES "futo_backups_schedule" ("id") ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT "futo_backups_repository_schedule_repository_fkey" FOREIGN KEY ("repository") REFERENCES "futo_backups_repositories" ("id") ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT "futo_backups_repository_schedule_pkey" PRIMARY KEY ("schedule", "repository")
);`.execute(db);
  await sql`CREATE INDEX "futo_backups_repository_schedule_schedule_idx" ON "futo_backups_repository_schedule" ("schedule");`.execute(db);
  await sql`CREATE INDEX "futo_backups_repository_schedule_repository_idx" ON "futo_backups_repository_schedule" ("repository");`.execute(db);
  await sql`CREATE TABLE "migration_overrides" (
  "name" character varying NOT NULL,
  "value" jsonb NOT NULL,
  CONSTRAINT "migration_overrides_pkey" PRIMARY KEY ("name")
);`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP TABLE "futo_backups_backends";`.execute(db);
  await sql`DROP TABLE "futo_backups_config";`.execute(db);
  await sql`DROP TABLE "futo_backups_jobs";`.execute(db);
  await sql`DROP TABLE "futo_backups_repositories";`.execute(db);
  await sql`DROP TABLE "futo_backups_schedule";`.execute(db);
  await sql`DROP TABLE "futo_backups_integrations_immich_config";`.execute(db);
  await sql`DROP TABLE "futo_backups_local_metrics";`.execute(db);
  await sql`DROP TABLE "futo_backups_repository_path";`.execute(db);
  await sql`DROP TABLE "futo_backups_repository_schedule";`.execute(db);
  await sql`DROP TABLE "migration_overrides";`.execute(db);
  await sql`DROP TYPE "futo_backups_job_name_enum";`.execute(db);
  await sql`DROP TYPE "futo_backups_job_status_enum";`.execute(db);
  await sql`DROP TYPE "futo_backups_configuration_key_enum";`.execute(db);
  await sql`DROP TYPE "futo_backups_last_backup_status_enum";`.execute(db);
}
