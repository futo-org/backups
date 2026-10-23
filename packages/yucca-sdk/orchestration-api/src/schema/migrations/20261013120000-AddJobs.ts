import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await db.schema
    .createTable('jobs')
    .addColumn('id', 'text', (col) => col.primaryKey())
    .addColumn('name', 'text', (col) => col.notNull())
    .addColumn('repositoryId', 'text', (col) => col.notNull())
    .addColumn('data', 'text', (col) => col.notNull())
    .addColumn('status', 'text', (col) =>
      col
        .notNull()
        .check(sql`status IN ('queued', 'running', 'complete', 'warn', 'failed', 'cancelled', 'incomplete')`),
    )
    .addColumn('outcome', 'text')
    .addColumn('logFilePath', 'text', (col) => col.notNull())
    .addColumn('queuedAt', 'datetime', (col) => col.notNull())
    .addColumn('start', 'datetime')
    .addColumn('end', 'datetime')
    .execute();
}

export async function down(db: Kysely<any>): Promise<void> {
  await db.schema.dropTable('jobs').execute();
}
