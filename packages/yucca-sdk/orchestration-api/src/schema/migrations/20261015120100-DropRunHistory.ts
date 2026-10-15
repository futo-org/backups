import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await db.schema.dropTable('runHistory').execute();
}

export async function down(db: Kysely<any>): Promise<void> {
  await db.schema
    .createTable('runHistory')
    .addColumn('id', 'text', (col) => col.primaryKey())
    .addColumn('repositoryId', 'text', (col) => col.references('repositories.id'))
    .addColumn('start', 'datetime')
    .addColumn('end', 'datetime')
    .addColumn('logFilePath', 'text')
    .addColumn('status', 'text', (col) =>
      col.check(sql`status IN ('incomplete', 'complete', 'warn', 'failed', 'cancelled')`),
    )
    .addColumn('type', 'text', (col) =>
      col
        .notNull()
        .defaultTo('backup')
        .check(sql`type IN ('backup', 'restore', 'forget')`),
    )
    .execute();

  await sql`
    INSERT INTO "runHistory" ("id", "repositoryId", "start", "end", "logFilePath", "status", "type")
    SELECT
      "id",
      "repositoryId",
      "start",
      "end",
      "logFilePath",
      CASE WHEN "status" IN ('queued', 'running') THEN 'incomplete' ELSE "status" END,
      CASE "name" WHEN 'repository-restore' THEN 'restore' WHEN 'repository-prune' THEN 'forget' ELSE 'backup' END
    FROM "jobs"
    WHERE "name" IN ('repository-backup', 'repository-restore', 'repository-prune')
  `.execute(db);
}
