export const MIB = 1 << 20;
export const SECONDS_PER_MONTH = (365.25 / 12) * 86_400;

export type UsagePeriodKind = 'hour' | 'day' | 'month';

export type UsageSample = { timestamp: Date; billableBytes: number };

export type UsagePeriod = { periodStart: Date; periodEnd: Date };

export const integrateByteSeconds = (samples: UsageSample[], { periodStart, periodEnd }: UsagePeriod): number => {
  const sorted = samples.toSorted((a, b) => a.timestamp.getTime() - b.timestamp.getTime());
  let total = 0;
  let cursor = periodStart.getTime();
  let bytes = 0;
  for (const sample of sorted) {
    const at = Math.max(sample.timestamp.getTime(), periodStart.getTime());
    if (at >= periodEnd.getTime()) {
      break;
    }
    total += bytes * (at - cursor);
    cursor = at;
    bytes = sample.billableBytes;
  }
  total += bytes * (periodEnd.getTime() - cursor);
  return total / 1000;
};

export const megabyteMonths = (byteSeconds: number): number => byteSeconds / (MIB * SECONDS_PER_MONTH);

export const periodStartOf = (kind: UsagePeriodKind, at: Date): Date => {
  switch (kind) {
    case 'hour': {
      return new Date(Date.UTC(at.getUTCFullYear(), at.getUTCMonth(), at.getUTCDate(), at.getUTCHours()));
    }
    case 'day': {
      return new Date(Date.UTC(at.getUTCFullYear(), at.getUTCMonth(), at.getUTCDate()));
    }
    case 'month': {
      return new Date(Date.UTC(at.getUTCFullYear(), at.getUTCMonth()));
    }
  }
};

export const nextPeriodStart = (kind: UsagePeriodKind, periodStart: Date): Date => {
  switch (kind) {
    case 'hour': {
      return new Date(periodStart.getTime() + 3_600_000);
    }
    case 'day': {
      return new Date(periodStart.getTime() + 86_400_000);
    }
    case 'month': {
      return new Date(Date.UTC(periodStart.getUTCFullYear(), periodStart.getUTCMonth() + 1));
    }
  }
};

export const defaultLookbackPeriods = (kind: UsagePeriodKind): number => {
  switch (kind) {
    case 'hour': {
      return 45 * 24;
    }
    case 'day': {
      return 45;
    }
    case 'month': {
      return 3;
    }
  }
};

export const elapsedPeriods = (kind: UsagePeriodKind, now: Date, lookback: number): UsagePeriod[] => {
  const periods: UsagePeriod[] = [];
  let periodEnd = periodStartOf(kind, now);
  for (let i = 0; i < lookback; i++) {
    const periodStart = previousPeriodStart(kind, periodEnd);
    periods.unshift({ periodStart, periodEnd });
    periodEnd = periodStart;
  }
  return periods;
};

const previousPeriodStart = (kind: UsagePeriodKind, periodEnd: Date): Date => {
  switch (kind) {
    case 'hour': {
      return new Date(periodEnd.getTime() - 3_600_000);
    }
    case 'day': {
      return new Date(periodEnd.getTime() - 86_400_000);
    }
    case 'month': {
      return new Date(Date.UTC(periodEnd.getUTCFullYear(), periodEnd.getUTCMonth() - 1));
    }
  }
};

export const usageId = (userId: string, periodStart: Date): string => `${userId}:${periodStart.toISOString()}`;
