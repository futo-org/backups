import { billableBytes } from '@common/server';
import { LoggerRepository } from '@common/server/otel';
import {
  BadRequestException,
  Injectable,
  NotFoundException,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { AuthDto } from 'src/dto/auth.dto.js';
import {
  BillingStatementListResponseDto,
  BillingStatusDto,
  BillingWebhookReceiptDto,
  StartSubscriptionResponseDto,
  SubscriptionPortalResponseDto,
} from 'src/dto/billing.dto.js';
import { BillingRepository } from 'src/repositories/billing.repository.js';
import {
  FutopayCustomerStatus,
  FutopayNotification,
  FutopayRepository,
  FutopayRequestError,
} from 'src/repositories/futopay.repository.js';
import { RepositoryRepository } from 'src/repositories/repository.repository.js';
import { BillingState } from 'src/schema/tables/user.table.js';

const toDate = (value: string | null | undefined) => (value ? new Date(value) : null);
// The meter and Pay count in MiB-based megabyte-months, so "GB" here is 1024³ to match
const GB = 1024 ** 3;

@Injectable()
export class BillingService {
  constructor(
    private readonly logger: LoggerRepository,
    private readonly billing: BillingRepository,
    private readonly futopay: FutopayRepository,
    private readonly repositories: RepositoryRepository,
  ) {}

  private ensureEnabled() {
    if (!this.futopay.enabled) {
      throw new ServiceUnavailableException('Billing is not configured');
    }
  }

  async getBillingStatus(auth: AuthDto, refresh?: boolean): Promise<BillingStatusDto> {
    this.ensureEnabled();
    let user = await this.billing.getUserBilling(auth.id);
    if (!user) {
      throw new NotFoundException('User missing');
    }

    // The page is served from what yucca already knows (users.billingState, kept
    // current by Pay's customer.state notifications) and never calls Pay per
    // view. The two exceptions: the caller asked (the return from checkout,
    // before the notification can have landed), and a cached state written
    // before Pay reported prices, which is re-read once and then cached again.
    const cachedBeforePricing =
      user.billingStatus !== 'new' && user.billingState != null && user.billingState.rate_cents_per_gb_month == null;
    if (refresh || cachedBeforePricing) {
      try {
        const status = await this.futopay.getStatus({ sub: user.sub, email: user.email });
        await this.billing.setBillingState(user.id, status.state, status);
        user = (await this.billing.getUserBilling(auth.id)) ?? user;
      } catch (error) {
        this.logger.warn(error, 'Could not refresh billing status from FUTO Pay');
      }
    }

    return this.toStatusDto(user.billingStatus, user.billingState, user.billingUpdatedAt, await this.storedGb(auth.id));
  }

  /** What the user stores right now, floored the way the metrics worker bills it, in GB. */
  private async storedGb(userId: string): Promise<number> {
    const repositories = await this.repositories.getByUser(userId);
    const bytes = repositories.reduce(
      (sum, repo) => sum + billableBytes(repo.connectionType, repo.meter?.sizeBytes ?? 0, repo.meter?.objectCount ?? 0),
      0,
    );
    return bytes / GB;
  }

  async listStatements(auth: AuthDto): Promise<BillingStatementListResponseDto> {
    this.ensureEnabled();
    return { statements: await this.billing.listStatements(auth.id) };
  }

  async startSubscription(auth: AuthDto, origin: string | undefined): Promise<StartSubscriptionResponseDto> {
    this.ensureEnabled();
    const user = await this.billing.getUserBilling(auth.id);
    if (!user) {
      throw new NotFoundException('User missing');
    }
    if (user.billingStatus === 'active') {
      throw new BadRequestException('Already subscribed');
    }

    const returnUrl = new URL('/dashboard/billing', origin ?? 'http://localhost:5173').href;
    try {
      const signup = await this.futopay.signup({ email: user.email, sub: user.sub, returnUrl });
      return { checkoutUrl: signup.checkout_url };
    } catch (error) {
      if (error instanceof FutopayRequestError && error.status === 409) {
        throw new BadRequestException('Already subscribed');
      }
      throw error;
    }
  }

  async openSubscriptionPortal(auth: AuthDto, origin: string | undefined): Promise<SubscriptionPortalResponseDto> {
    this.ensureEnabled();
    const user = await this.billing.getUserBilling(auth.id);
    if (!user) {
      throw new NotFoundException('User missing');
    }
    if (user.billingStatus !== 'active' && user.billingStatus !== 'inactive') {
      throw new BadRequestException('No subscription to manage');
    }

    // Pay mints a short-lived Polar customer-portal session; the portal sends
    // the browser back here when the customer is done
    const returnUrl = new URL('/dashboard/billing', origin ?? 'http://localhost:5173').href;
    try {
      const portal = await this.futopay.portal({ email: user.email, sub: user.sub, returnUrl });
      return { portalUrl: portal.portal_url };
    } catch (error) {
      if (error instanceof FutopayRequestError && error.status === 404) {
        throw new BadRequestException('No subscription to manage');
      }
      throw error;
    }
  }

  async futopayWebhook(
    rawBody: Buffer | string | null,
    headers: Record<string, string>,
  ): Promise<BillingWebhookReceiptDto> {
    this.ensureEnabled();
    if (!rawBody) {
      throw new BadRequestException('Missing body');
    }

    let notification: FutopayNotification;
    try {
      notification = this.futopay.verifyWebhook(rawBody, headers);
    } catch (error) {
      this.logger.warn(error, 'Rejected FUTO Pay webhook');
      throw new UnauthorizedException('Invalid webhook signature');
    }

    const deliveryId = headers['webhook-id'] ?? notification.id;
    if (!(await this.billing.recordDelivery(deliveryId, notification.event))) {
      return { status: 'duplicate' };
    }

    const user = await this.billing.findUser({
      sub: notification.data.external_customer_id,
      email: notification.data.email,
    });
    if (!user) {
      this.logger.warn(
        `FUTO Pay ${notification.event} for unknown customer ${notification.data.external_customer_id ?? notification.data.email}`,
      );
      return { status: 'received' };
    }

    if (notification.event === 'customer.state') {
      await this.billing.setBillingState(user.id, notification.data.state, this.toBillingState(notification.data));
    }

    if (notification.event === 'usage.paid') {
      const { data } = notification;
      await this.billing.upsertStatement({
        orderId: data.polar_order_id ?? deliveryId,
        userId: user.id,
        billingReason: data.billing_reason ?? '',
        periodStart: toDate(data.period_start),
        periodEnd: toDate(data.period_end),
        gigabyteMonthsUsed: data.gigabyte_months_used ?? 0,
        amountCents: data.amount_cents ?? 0,
        currency: data.currency ?? '',
        usageIds: data.usage_ids ?? [],
        raw: data,
      });
    }

    this.logger.info(`FUTO Pay ${notification.event} for user ${user.id}: ${notification.data.state}`);
    return { status: 'received' };
  }

  private toBillingState(status: FutopayCustomerStatus): BillingState {
    return {
      state: status.state,
      polar_status: status.polar_status,
      subscription_id: status.subscription_id,
      phase: status.phase,
      current_period_start: status.current_period_start,
      period_gb_months: status.period_gb_months,
      period_usage: status.period_usage ?? [],
      current_period_end: status.current_period_end,
      ends_at: status.ends_at,
      reason: status.reason,
      credit_gb_months: status.credit_gb_months,
      credit_used_gb_months: status.credit_used_gb_months,
      credit_remaining_gb_months: status.credit_remaining_gb_months,
      forwarded_gb_months: status.forwarded_gb_months,
      pending_gb_months: status.pending_gb_months,
      pending_amount_cents: status.pending_amount_cents,
      currency: status.currency,
      rate_cents_per_gb_month: status.rate_cents_per_gb_month,
      starter_price_cents: status.starter_price_cents,
      starter_credit_cents: status.starter_credit_cents,
    };
  }

  private toStatusDto(
    billingStatus: string,
    state: BillingState | null,
    updatedAt: Date | null,
    storedGb: number,
  ): BillingStatusDto {
    const active = billingStatus === 'active';
    const status =
      billingStatus !== 'active' && billingStatus !== 'inactive'
        ? 'new'
        : state?.reason === 'past_due'
          ? 'past_due'
          : active
            ? state?.ends_at
              ? 'pending_cancellation'
              : 'active'
            : 'ended';
    return {
      status,
      subscriptionActive: active,
      polarStatus: state?.polar_status ?? null,
      subscriptionId: state?.subscription_id ?? null,
      phase: state?.phase ?? null,
      reason: state?.reason ?? null,
      currentPeriodEnd: toDate(state?.current_period_end),
      endsAt: toDate(state?.ends_at),
      creditGbMonths: state?.credit_gb_months ?? 0,
      creditUsedGbMonths: state?.credit_used_gb_months ?? 0,
      creditRemainingGbMonths: state?.credit_remaining_gb_months ?? 0,
      forwardedGbMonths: state?.forwarded_gb_months ?? 0,
      currentPeriodStart: toDate(state?.current_period_start),
      periodGbMonths: state?.period_gb_months ?? 0,
      periodUsage: (state?.period_usage ?? []).map((d) => ({ date: d.date, gbMonths: d.gb_months })),
      pendingGbMonths: state?.pending_gb_months ?? 0,
      pendingAmountCents: state?.pending_amount_cents ?? 0,
      currency: state?.currency ?? 'usd',
      rateCentsPerGbMonth: state?.rate_cents_per_gb_month ?? 0,
      starterPriceCents: state?.starter_price_cents ?? 0,
      starterCreditCents: state?.starter_credit_cents ?? 0,
      storedGb,
      updatedAt,
    };
  }
}
