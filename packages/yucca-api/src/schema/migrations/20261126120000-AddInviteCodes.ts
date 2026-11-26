import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`CREATE TABLE "inviteCodes" (
  "id" uuid NOT NULL DEFAULT gen_random_uuid(),
  "code" character varying NOT NULL,
  "name" character varying NOT NULL,
  "maxUses" integer,
  "expiresAt" timestamp with time zone,
  "revokedAt" timestamp with time zone,
  "createdAt" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "inviteCodes_code_uq" UNIQUE ("code"),
  CONSTRAINT "inviteCodes_name_uq" UNIQUE ("name"),
  CONSTRAINT "inviteCodes_pkey" PRIMARY KEY ("id")
);`.execute(db);
  await sql`CREATE TABLE "inviteCodeRedemptions" (
  "id" uuid NOT NULL DEFAULT gen_random_uuid(),
  "inviteCodeId" uuid NOT NULL,
  "userId" uuid,
  "createdAt" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "inviteCodeRedemptions_inviteCodeId_fkey" FOREIGN KEY ("inviteCodeId") REFERENCES "inviteCodes" ("id") ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT "inviteCodeRedemptions_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users" ("id") ON UPDATE CASCADE ON DELETE SET NULL,
  CONSTRAINT "inviteCodeRedemptions_userId_uq" UNIQUE ("userId"),
  CONSTRAINT "inviteCodeRedemptions_pkey" PRIMARY KEY ("id")
);`.execute(db);
  await sql`CREATE INDEX "inviteCodeRedemptions_inviteCodeId_idx" ON "inviteCodeRedemptions" ("inviteCodeId");`.execute(
    db,
  );
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP TABLE "inviteCodeRedemptions";`.execute(db);
  await sql`DROP TABLE "inviteCodes";`.execute(db);
}
