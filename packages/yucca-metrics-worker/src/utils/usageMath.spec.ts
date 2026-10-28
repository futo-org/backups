import {
  defaultLookbackPeriods,
  elapsedPeriods,
  integrateByteSeconds,
  megabyteMonths,
  MIB,
  nextPeriodStart,
  periodStartOf,
  SECONDS_PER_MONTH,
  usageId,
} from './usageMath.js';

const day = (iso: string) => new Date(iso);

describe('integrateByteSeconds', () => {
  const period = { periodStart: day('2026-10-01T00:00:00Z'), periodEnd: day('2026-10-02T00:00:00Z') };

  it('holds a sample taken before the period for the whole period', () => {
    const samples = [{ timestamp: day('2026-09-30T23:55:00Z'), billableBytes: 10 * MIB }];
    expect(integrateByteSeconds(samples, period)).toBe(10 * MIB * 86_400);
  });

  it('counts nothing before the first sample inside the period', () => {
    const samples = [{ timestamp: day('2026-10-01T12:00:00Z'), billableBytes: 4 * MIB }];
    expect(integrateByteSeconds(samples, period)).toBe(4 * MIB * 43_200);
  });

  it('steps between samples and holds the last one to the period end', () => {
    const samples = [
      { timestamp: day('2026-09-30T00:00:00Z'), billableBytes: 2 * MIB },
      { timestamp: day('2026-10-01T06:00:00Z'), billableBytes: 6 * MIB },
      { timestamp: day('2026-10-01T18:00:00Z'), billableBytes: 0 },
    ];
    expect(integrateByteSeconds(samples, period)).toBe(2 * MIB * 21_600 + 6 * MIB * 43_200);
  });

  it('ignores samples at or after the period end', () => {
    const samples = [
      { timestamp: day('2026-09-30T00:00:00Z'), billableBytes: MIB },
      { timestamp: day('2026-10-02T00:00:00Z'), billableBytes: 99 * MIB },
    ];
    expect(integrateByteSeconds(samples, period)).toBe(MIB * 86_400);
  });

  it('is zero without samples', () => {
    expect(integrateByteSeconds([], period)).toBe(0);
  });
});

describe('megabyteMonths', () => {
  it('converts one mebibyte held for one month to one megabyte-month', () => {
    expect(megabyteMonths(MIB * SECONDS_PER_MONTH)).toBeCloseTo(1, 9);
  });

  it('converts 10 GiB held for one month to 10240 megabyte-months', () => {
    expect(megabyteMonths(10 * 1024 * MIB * SECONDS_PER_MONTH)).toBeCloseTo(10_240, 6);
  });
});

describe('periods', () => {
  it('aligns to UTC boundaries', () => {
    const at = day('2026-10-27T13:45:10Z');
    expect(periodStartOf('hour', at).toISOString()).toBe('2026-10-27T13:00:00.000Z');
    expect(periodStartOf('day', at).toISOString()).toBe('2026-10-27T00:00:00.000Z');
    expect(periodStartOf('month', at).toISOString()).toBe('2026-10-01T00:00:00.000Z');
  });

  it('advances months by calendar month', () => {
    expect(nextPeriodStart('month', day('2026-12-01T00:00:00Z')).toISOString()).toBe('2027-01-01T00:00:00.000Z');
    expect(nextPeriodStart('day', day('2026-10-31T00:00:00Z')).toISOString()).toBe('2026-11-01T00:00:00.000Z');
  });

  it('lists the elapsed periods oldest first, excluding the current one', () => {
    const periods = elapsedPeriods('day', day('2026-10-27T13:45:10Z'), 2);
    expect(periods.map((p) => [p.periodStart.toISOString(), p.periodEnd.toISOString()])).toEqual([
      ['2026-10-25T00:00:00.000Z', '2026-10-26T00:00:00.000Z'],
      ['2026-10-26T00:00:00.000Z', '2026-10-27T00:00:00.000Z'],
    ]);
  });

  it('derives a stable usage id from the user and period start', () => {
    expect(usageId('user-1', day('2026-10-26T00:00:00Z'))).toBe('user-1:2026-10-26T00:00:00.000Z');
  });
});

describe('defaultLookbackPeriods', () => {
  it('covers about six weeks of catch-up whatever the period length', () => {
    expect(defaultLookbackPeriods('hour')).toBe(45 * 24);
    expect(defaultLookbackPeriods('day')).toBe(45);
    expect(defaultLookbackPeriods('month')).toBe(3);
  });
});
