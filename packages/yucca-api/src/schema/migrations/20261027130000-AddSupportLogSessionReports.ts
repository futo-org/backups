import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`CREATE TABLE "supportLogSessionReports" (
  "id" uuid NOT NULL,
  "sessionId" uuid NOT NULL,
  "createdAt" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "supportLogSessionReports_sessionId_fkey" FOREIGN KEY ("sessionId") REFERENCES "supportLogSessions" ("id") ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT "supportLogSessionReports_pkey" PRIMARY KEY ("id")
);`.execute(db);
  await sql`CREATE INDEX "supportLogSessionReports_sessionId_idx" ON "supportLogSessionReports" ("sessionId");`.execute(
    db,
  );
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP TABLE "supportLogSessionReports";`.execute(db);
}
