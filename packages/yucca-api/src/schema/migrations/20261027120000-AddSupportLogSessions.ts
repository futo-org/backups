import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`CREATE TABLE "supportLogSessions" (
  "id" uuid NOT NULL DEFAULT gen_random_uuid(),
  "userId" uuid NOT NULL,
  "connectionId" uuid,
  "jobId" character varying NOT NULL,
  "jobName" character varying NOT NULL,
  "includesPaths" boolean NOT NULL,
  "clientVersion" character varying,
  "lineCount" bigint NOT NULL DEFAULT 0,
  "byteCount" bigint NOT NULL DEFAULT 0,
  "batchCount" bigint NOT NULL DEFAULT 0,
  "droppedLineCount" bigint NOT NULL DEFAULT 0,
  "createdAt" timestamp with time zone NOT NULL DEFAULT now(),
  "lastBatchAt" timestamp with time zone,
  "finishedAt" timestamp with time zone,
  CONSTRAINT "supportLogSessions_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users" ("id") ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT "supportLogSessions_connectionId_fkey" FOREIGN KEY ("connectionId") REFERENCES "connections" ("id") ON UPDATE CASCADE ON DELETE SET NULL,
  CONSTRAINT "supportLogSessions_pkey" PRIMARY KEY ("id")
);`.execute(db);
  await sql`CREATE INDEX "supportLogSessions_userId_idx" ON "supportLogSessions" ("userId");`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP TABLE "supportLogSessions";`.execute(db);
}
