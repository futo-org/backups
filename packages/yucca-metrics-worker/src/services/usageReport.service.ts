import { billableBytes } from '@common/server';
import { LoggerRepository } from '@common/server/otel';
import { Injectable } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { env } from 'src/env.js';
import { FutopayUsageRepository, FutopayUsageResult } from 'src/repositories/futopayUsage.repository.js';
import {
  MeterSample,
  UsageReportRepository,
  UsageReportRow,
  UsageReportShare,
} from 'src/repositories/usageReport.repository.js';
import {
  defaultLookbackPeriods,
  elapsedPeriods,
  integrateByteSeconds,
  megabyteMonths,
  usageId,
  UsagePeriod,
  UsageSample,
} from 'src/utils/usageMath.js';

const BATCH_SIZE = 500;

export const toBillableSamples = (samples: MeterSample[]): UsageSample[] =>
  samples.map((sample) => ({
    timestamp: sample.timestamp,
    billableBytes: billableBytes(sample.connectionType, sample.sizeBytes, sample.objectCount),
  }));

/** Each repository's megabyte-months over the period, in sample order. */
export const megabyteMonthsByRepository = (samples: MeterSample[], period: UsagePeriod): UsageReportShare[] => {
  const byRepository = new Map<string, MeterSample[]>();
  for (const sample of samples) {
    const list = byRepository.get(sample.repositoryId) ?? [];
    list.push(sample);
    byRepository.set(sample.repositoryId, list);
  }
  return [...byRepository.entries()].map(([repositoryId, repositorySamples]) => ({
    repository_id: repositoryId,
    name: repositorySamples.find((sample) => sample.repositoryName)?.repositoryName ?? null,
    megabyte_months: megabyteMonths(integrateByteSeconds(toBillableSamples(repositorySamples), period)),
  }));
};

export const megabyteMonthsForUser = (samples: MeterSample[], period: UsagePeriod): number =>
  megabyteMonthsByRepository(samples, period).reduce((total, repository) => total + repository.megabyte_months, 0);

@Injectable()
export class UsageReportService {
  // The scheduled run and the internal close-period endpoint both send; two
  // sends overlapping would both read the same pending rows and post them
  // twice (Pay answers duplicate, but a 200 should mean sent once), so a
  // caller joins the send in flight instead of starting another
  private sending: Promise<FutopayUsageResult[]> | null = null;

  constructor(
    private readonly logger: LoggerRepository,
    private readonly reports: UsageReportRepository,
    private readonly futopay: FutopayUsageRepository,
  ) {}

  @Cron('*/15 * * * *')
  async run() {
    if (!this.futopay.enabled) {
      return;
    }
    try {
      const lookback = env.FUTOPAY_USAGE_LOOKBACK_PERIODS ?? defaultLookbackPeriods(env.FUTOPAY_USAGE_PERIOD);
      for (const period of elapsedPeriods(env.FUTOPAY_USAGE_PERIOD, new Date(), lookback)) {
        await this.closePeriod(period);
      }
      await this.sendPending();
    } catch (error) {
      this.logger.error(error, 'Usage reporting run failed');
    }
  }

  /** Closes the period for every billable user, or for the one whose sub is given. */
  async closePeriod(period: UsagePeriod, sub?: string): Promise<number> {
    let created = 0;
    for (const user of await this.reports.listBillableUsers()) {
      if (sub !== undefined && user.sub !== sub) {
        continue;
      }
      const samples = await this.reports.getSamples(user.id, period.periodStart, period.periodEnd);
      if (samples.length === 0) {
        continue;
      }
      const repositories = megabyteMonthsByRepository(samples, period);
      const id = await this.reports.create({
        userId: user.id,
        periodStart: period.periodStart,
        periodEnd: period.periodEnd,
        megabyteMonths: repositories.reduce((total, repository) => total + repository.megabyte_months, 0),
        repositories,
      });
      if (id) {
        created++;
      }
    }
    if (created > 0) {
      this.logger.info(`Closed usage period ${period.periodStart.toISOString()} for ${created} users`);
    }
    return created;
  }

  sendPending(): Promise<FutopayUsageResult[]> {
    if (!this.sending) {
      this.sending = this.sendPendingNow().finally(() => {
        this.sending = null;
      });
    }
    return this.sending;
  }

  private async sendPendingNow(): Promise<FutopayUsageResult[]> {
    const pending = await this.reports.listPending(BATCH_SIZE);
    if (pending.length === 0) {
      return [];
    }

    let results: FutopayUsageResult[];
    try {
      results = await this.futopay.report(pending.map((row) => this.toReport(row)));
    } catch (error) {
      await this.reports.markFailed(
        pending.map((row) => row.id),
        error instanceof Error ? error.message : String(error),
      );
      throw error;
    }

    const byUsageId = new Map(results.map((result) => [result.usage_id, result]));
    for (const row of pending) {
      const result = byUsageId.get(usageId(row.userId, row.periodStart));
      if (!result) {
        await this.reports.markFailed([row.id], 'FUTO Pay returned no result for this usage_id');
        continue;
      }
      await this.reports.markSettled(row.id, result.status === 'not_billable' ? 'not_billable' : 'sent', result);
    }
    this.logger.info(`Reported ${pending.length} usage periods to FUTO Pay`);
    return results;
  }

  private toReport(row: UsageReportRow) {
    return {
      usage_id: usageId(row.userId, row.periodStart),
      external_customer_id: row.sub,
      email: row.email,
      megabyte_months: row.megabyteMonths,
      period_start: row.periodStart.toISOString(),
      period_end: row.periodEnd.toISOString(),
      // Rows written while the column was stored double-encoded read back as a string
      repositories:
        typeof row.repositories === 'string'
          ? (JSON.parse(row.repositories) as UsageReportShare[])
          : (row.repositories ?? []),
    };
  }
}
