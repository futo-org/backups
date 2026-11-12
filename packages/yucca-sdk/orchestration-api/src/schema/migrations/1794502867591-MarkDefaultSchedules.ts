import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`UPDATE "futo_backups_schedule" SET "cron" = '@daily' WHERE "cron" = '0 3 * * *';`.execute(db);
  await sql`UPDATE "futo_backups_schedule" SET "cron" = '@weekly' WHERE "cron" = '0 3 * * 0';`.execute(db);
  await sql`UPDATE "futo_backups_schedule" SET "cron" = '@monthly' WHERE "cron" = '0 3 1 * *';`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`UPDATE "futo_backups_schedule" SET "cron" = '0 3 * * *' WHERE "cron" = '@daily';`.execute(db);
  await sql`UPDATE "futo_backups_schedule" SET "cron" = '0 3 * * 0' WHERE "cron" = '@weekly';`.execute(db);
  await sql`UPDATE "futo_backups_schedule" SET "cron" = '0 3 1 * *' WHERE "cron" = '@monthly';`.execute(db);
}
