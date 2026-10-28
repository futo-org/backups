import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`ALTER TABLE "users" ADD "billingStatus" text NOT NULL DEFAULT 'new';`.execute(db);
  await sql`ALTER TABLE "users" ADD "billingState" jsonb;`.execute(db);
  await sql`ALTER TABLE "users" ADD "billingUpdatedAt" timestamp with time zone;`.execute(db);
  await sql`CREATE TABLE "billingStatements" (
  "orderId" text NOT NULL,
  "userId" uuid NOT NULL,
  "billingReason" text NOT NULL,
  "periodStart" timestamp with time zone,
  "periodEnd" timestamp with time zone,
  "gigabyteMonthsUsed" double precision NOT NULL,
  "amountCents" integer NOT NULL,
  "currency" text NOT NULL,
  "usageIds" jsonb NOT NULL,
  "raw" jsonb NOT NULL,
  "createdAt" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "billingStatements_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users" ("id") ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT "billingStatements_pkey" PRIMARY KEY ("orderId")
);`.execute(db);
  await sql`CREATE INDEX "billingStatements_userId_idx" ON "billingStatements" ("userId");`.execute(db);
  await sql`CREATE TABLE "billingWebhookDeliveries" (
  "id" text NOT NULL,
  "event" text NOT NULL,
  "receivedAt" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "billingWebhookDeliveries_pkey" PRIMARY KEY ("id")
);`.execute(db);
  await sql`CREATE TABLE "usageReports" (
  "id" uuid NOT NULL DEFAULT gen_random_uuid(),
  "userId" uuid NOT NULL,
  "periodStart" timestamp with time zone NOT NULL,
  "periodEnd" timestamp with time zone NOT NULL,
  "megabyteMonths" double precision NOT NULL,
  "status" text NOT NULL DEFAULT 'pending',
  "attempts" integer NOT NULL DEFAULT 0,
  "lastError" text,
  "response" jsonb,
  "createdAt" timestamp with time zone NOT NULL DEFAULT now(),
  "sentAt" timestamp with time zone,
  CONSTRAINT "usageReports_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users" ("id") ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT "usageReports_pkey" PRIMARY KEY ("id"),
  CONSTRAINT "usageReports_userId_periodStart_uq" UNIQUE ("userId", "periodStart")
);`.execute(db);
  await sql`CREATE INDEX "usageReports_userId_idx" ON "usageReports" ("userId");`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP TABLE "usageReports";`.execute(db);
  await sql`DROP TABLE "billingWebhookDeliveries";`.execute(db);
  await sql`DROP TABLE "billingStatements";`.execute(db);
  await sql`ALTER TABLE "users" DROP COLUMN "billingUpdatedAt";`.execute(db);
  await sql`ALTER TABLE "users" DROP COLUMN "billingState";`.execute(db);
  await sql`ALTER TABLE "users" DROP COLUMN "billingStatus";`.execute(db);
}
