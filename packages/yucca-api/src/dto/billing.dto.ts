import { isoDatetimeToDate } from '@common/server';
import { createZodDto } from 'nestjs-zod';
import { z } from 'zod';

// `pending_cancellation` is an active subscription with an end date: backups
// keep running and nothing is billed differently until then, so Pay still
// reports it active; it is split out here so the page can say what is coming
// `past_due` is a failed renewal charge while Polar retries it (backups keep
// running or pause, see subscriptionActive); `ended` is everything else that
// is over: cancelled and past its end date, retries exhausted, never completed
export const BillingStatus = ['new', 'active', 'pending_cancellation', 'past_due', 'ended'] as const;

const BillingStatusSchema = z
  .object({
    status: z.enum(BillingStatus).meta({ id: 'BillingStatus' }),
    subscriptionActive: z.boolean(),
    polarStatus: z.string().nullable(),
    subscriptionId: z.string().nullable(),
    phase: z.string().nullable(),
    reason: z.string().nullable(),
    currentPeriodEnd: isoDatetimeToDate.nullable(),
    endsAt: isoDatetimeToDate.nullable(),
    creditGbMonths: z.number(),
    creditUsedGbMonths: z.number(),
    creditRemainingGbMonths: z.number(),
    forwardedGbMonths: z.number(),
    currentPeriodStart: isoDatetimeToDate.nullable(),
    // Usage reported so far in the current billing period, credited or not
    periodGbMonths: z.number(),
    // The same, per UTC day from the first reported day to the last (gaps are zero)
    periodUsage: z.array(z.object({ date: z.string(), gbMonths: z.number() }).meta({ id: 'BillingDailyUsage' })),
    // Usage beyond the credit that no statement has covered yet: what the next renewal charges for
    pendingGbMonths: z.number(),
    pendingAmountCents: z.number(),
    // The price list, so the page can explain the plan and project the cost
    currency: z.string(),
    rateCentsPerGbMonth: z.number(),
    starterPriceCents: z.number(),
    starterCreditCents: z.number(),
    // Billable bytes across the user's repositories right now, in GB, for the projection
    storedGb: z.number(),
    updatedAt: isoDatetimeToDate.nullable(),
  })
  .meta({ id: 'BillingStatusDto' });

const BillingStatementSchema = z
  .object({
    orderId: z.string(),
    billingReason: z.string(),
    periodStart: isoDatetimeToDate.nullable(),
    periodEnd: isoDatetimeToDate.nullable(),
    gigabyteMonthsUsed: z.number(),
    amountCents: z.number(),
    currency: z.string(),
    createdAt: isoDatetimeToDate,
  })
  .meta({ id: 'BillingStatementDto' });

const BillingStatementListResponseSchema = z
  .object({ statements: z.array(BillingStatementSchema) })
  .meta({ id: 'BillingStatementListResponseDto' });

const StartSubscriptionResponseSchema = z
  .object({ checkoutUrl: z.string() })
  .meta({ id: 'StartSubscriptionResponseDto' });

const SubscriptionPortalResponseSchema = z
  .object({ portalUrl: z.string() })
  .meta({ id: 'SubscriptionPortalResponseDto' });

const WebhookReceiptSchema = z
  .object({ status: z.enum(['received', 'duplicate']) })
  .meta({ id: 'BillingWebhookReceiptDto' });

export class BillingStatusDto extends createZodDto(BillingStatusSchema, { codec: true }) {}
export class BillingStatementDto extends createZodDto(BillingStatementSchema, { codec: true }) {}
export class BillingStatementListResponseDto extends createZodDto(BillingStatementListResponseSchema, {
  codec: true,
}) {}
export class StartSubscriptionResponseDto extends createZodDto(StartSubscriptionResponseSchema) {}
export class SubscriptionPortalResponseDto extends createZodDto(SubscriptionPortalResponseSchema) {}
export class BillingWebhookReceiptDto extends createZodDto(WebhookReceiptSchema) {}
