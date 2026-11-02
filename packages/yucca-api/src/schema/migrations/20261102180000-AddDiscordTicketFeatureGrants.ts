import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`CREATE TABLE "discordTicketFeatureGrants" (
  "id" uuid NOT NULL DEFAULT gen_random_uuid(),
  "threadId" character varying NOT NULL,
  "userId" uuid NOT NULL,
  "flag" character varying NOT NULL,
  "createdAt" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "discordTicketFeatureGrants_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users" ("id") ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT "discordTicketFeatureGrants_threadId_userId_flag_uq" UNIQUE ("threadId", "userId", "flag"),
  CONSTRAINT "discordTicketFeatureGrants_pkey" PRIMARY KEY ("id")
);`.execute(db);
  await sql`CREATE INDEX "discordTicketFeatureGrants_userId_idx" ON "discordTicketFeatureGrants" ("userId");`.execute(
    db,
  );
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP TABLE "discordTicketFeatureGrants";`.execute(db);
}
