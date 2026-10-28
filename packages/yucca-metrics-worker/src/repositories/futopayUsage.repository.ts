import { Injectable } from '@nestjs/common';
import { env } from 'src/env.js';

export type FutopayUsageShare = {
  repository_id: string;
  name: string | null;
  megabyte_months: number;
};

export type FutopayUsageReport = {
  usage_id: string;
  external_customer_id: string;
  email: string;
  megabyte_months: number;
  period_start: string;
  period_end: string;
  // The split of megabyte_months per repository (the bucket Pay could not
  // otherwise name); informational, and its sum must not exceed the total
  repositories: FutopayUsageShare[];
};

export type FutopayUsageResult = {
  usage_id: string;
  status: 'received' | 'duplicate' | 'not_billable';
  state: string;
  settlement?: string | null;
  credited_gb_months?: number;
  forwarded_gb_months?: number;
  credit_remaining_gb_months?: number;
  detail?: string | null;
};

@Injectable()
export class FutopayUsageRepository {
  get enabled(): boolean {
    return Boolean(env.FUTOPAY_URL);
  }

  async report(reports: FutopayUsageReport[]): Promise<FutopayUsageResult[]> {
    const response = await fetch(new URL(`/api/v1/cloud/${env.FUTOPAY_ORG_SLUG}/usage`, env.FUTOPAY_URL), {
      method: 'POST',
      // Pay logs every Cloud API call with its User-Agent, so name the caller
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${env.FUTOPAY_API_KEY}`,
        'User-Agent': 'yucca-metrics-worker',
      },
      body: JSON.stringify({ reports }),
    });
    if (!response.ok) {
      throw new Error(
        `FUTO Pay POST /usage failed: ${response.status} ${response.statusText} — ${await response.text()}`,
      );
    }
    const { results } = (await response.json()) as { results: FutopayUsageResult[] };
    return results;
  }
}
