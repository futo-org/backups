import { Injectable } from '@nestjs/common';
import { env } from 'src/env.js';
import { Webhook } from 'standardwebhooks';

export type FutopayCustomerStatus = {
  email: string | null;
  external_customer_id: string | null;
  state: 'new' | 'active' | 'inactive';
  polar_status: string | null;
  subscription_id: string | null;
  phase: string | null;
  current_period_start: string | null;
  current_period_end: string | null;
  ends_at: string | null;
  reason: string | null;
  credit_gb_months: number;
  credit_used_gb_months: number;
  credit_remaining_gb_months: number;
  forwarded_gb_months: number;
  // Reported so far in the current billing period, credited or not
  period_gb_months: number;
  // The same, day by day (UTC): what the Billing page draws once the credit is spent
  period_usage?: { date: string; gb_months: number }[];
  // Beyond the credit and not yet on a statement: what the next renewal charges for
  pending_gb_months: number;
  pending_amount_cents: number;
  // The price list, present even before a subscription exists
  currency: string;
  rate_cents_per_gb_month: number;
  starter_price_cents: number;
  starter_credit_cents: number;
};

export type FutopaySignupResponse = { checkout_id: string; checkout_url: string; state: string };

export type FutopayPortalResponse = { portal_url: string; state: string; subscription_id: string };

export type FutopayNotification = {
  id: string;
  event: 'customer.state' | 'usage.paid';
  created_at: string;
  data: FutopayCustomerStatus & {
    polar_order_id?: string;
    billing_reason?: string;
    period_start?: string | null;
    period_end?: string | null;
    gigabyte_months_used?: number;
    amount_cents?: number;
    currency?: string;
    usage_ids?: string[];
  };
};

export class FutopayRequestError extends Error {
  constructor(
    readonly status: number,
    readonly body: string,
  ) {
    super(`FUTO Pay responded ${status}: ${body}`);
  }
}

@Injectable()
export class FutopayRepository {
  get enabled(): boolean {
    return Boolean(env.FUTOPAY_URL);
  }

  getStatus(query: { sub: string; email: string }): Promise<FutopayCustomerStatus> {
    const url = this.url('customers/status');
    url.searchParams.set('external_customer_id', query.sub);
    url.searchParams.set('email', query.email);
    return this.request<FutopayCustomerStatus>(url, { method: 'GET' });
  }

  signup(body: { email: string; sub: string; returnUrl: string }): Promise<FutopaySignupResponse> {
    return this.request<FutopaySignupResponse>(this.url('customers/signup'), {
      method: 'POST',
      body: JSON.stringify({ email: body.email, external_customer_id: body.sub, return_url: body.returnUrl }),
    });
  }

  portal(body: { email: string; sub: string; returnUrl: string }): Promise<FutopayPortalResponse> {
    return this.request<FutopayPortalResponse>(this.url('customers/portal'), {
      method: 'POST',
      body: JSON.stringify({ email: body.email, external_customer_id: body.sub, return_url: body.returnUrl }),
    });
  }

  verifyWebhook(rawBody: string | Buffer, headers: Record<string, string>): FutopayNotification {
    return new Webhook(env.FUTOPAY_WEBHOOK_SECRET).verify(rawBody, headers) as FutopayNotification;
  }

  private url(path: string): URL {
    return new URL(`/api/v1/cloud/${env.FUTOPAY_ORG_SLUG}/${path}`, env.FUTOPAY_URL);
  }

  private async request<T>(url: URL, init: RequestInit): Promise<T> {
    const response = await fetch(url, {
      ...init,
      // Pay logs every Cloud API call with its User-Agent, so name the caller
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${env.FUTOPAY_API_KEY}`,
        'User-Agent': 'yucca-api',
      },
    });
    if (!response.ok) {
      throw new FutopayRequestError(response.status, await response.text());
    }
    return (await response.json()) as T;
  }
}
