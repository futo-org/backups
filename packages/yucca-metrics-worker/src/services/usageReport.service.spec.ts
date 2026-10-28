import { jest } from '@jest/globals';
import { MIB, SECONDS_PER_MONTH } from 'src/utils/usageMath.js';
import { megabyteMonthsForUser, UsageReportService } from './usageReport.service.js';

const period = { periodStart: new Date('2026-10-01T00:00:00Z'), periodEnd: new Date('2026-10-02T00:00:00Z') };
const daysPerMonth = SECONDS_PER_MONTH / 86_400;

describe('megabyteMonthsForUser', () => {
  it('sums repositories and applies the per-type floor per sample', () => {
    const samples = [
      {
        repositoryId: 'r1',
        connectionType: 'immich',
        timestamp: new Date('2026-09-30T00:00:00Z'),
        sizeBytes: 10 * MIB,
        objectCount: 1000,
      },
      {
        repositoryId: 'r2',
        connectionType: 'restic',
        timestamp: new Date('2026-09-30T00:00:00Z'),
        sizeBytes: 1024,
        objectCount: 5,
      },
    ];
    expect(megabyteMonthsForUser(samples, period)).toBeCloseTo((10 + 5) / daysPerMonth, 9);
  });

  it('keeps repositories independent when their samples interleave', () => {
    const samples = [
      {
        repositoryId: 'r1',
        connectionType: 'immich',
        timestamp: new Date('2026-10-01T00:00:00Z'),
        sizeBytes: 2 * MIB,
        objectCount: 1,
      },
      {
        repositoryId: 'r2',
        connectionType: 'immich',
        timestamp: new Date('2026-10-01T12:00:00Z'),
        sizeBytes: 4 * MIB,
        objectCount: 1,
      },
    ];
    expect(megabyteMonthsForUser(samples, period)).toBeCloseTo((2 + 2) / daysPerMonth, 9);
  });
});

const row = (id: string, userId: string) => ({
  id,
  userId,
  sub: `sub-${userId}`,
  email: `${userId}@example.test`,
  periodStart: period.periodStart,
  periodEnd: period.periodEnd,
  megabyteMonths: 1,
  status: 'pending',
  attempts: 0,
});

describe(UsageReportService.name, () => {
  const logger = { info: jest.fn(), warn: jest.fn(), error: jest.fn() };
  const reports = {
    listBillableUsers: jest.fn<() => Promise<{ id: string; sub: string; email: string }[]>>(),
    getSamples: jest.fn<() => Promise<any[]>>(),
    create: jest.fn<() => Promise<string | null>>(),
    listPending: jest.fn<() => Promise<any[]>>(),
    markSettled: jest.fn(),
    markFailed: jest.fn(),
  };
  const futopay = { enabled: true, report: jest.fn<() => Promise<any[]>>() };

  const sut = () => new UsageReportService(logger as never, reports as never, futopay as never);

  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('creates one report per user with samples and skips users without any', async () => {
    reports.listBillableUsers.mockResolvedValue([
      { id: 'u1', sub: 's1', email: 'a@example.test' },
      { id: 'u2', sub: 's2', email: 'b@example.test' },
    ]);
    reports.getSamples.mockResolvedValueOnce([
      { repositoryId: 'r', connectionType: 'immich', timestamp: period.periodStart, sizeBytes: MIB, objectCount: 1 },
    ]);
    reports.getSamples.mockResolvedValueOnce([]);
    reports.create.mockResolvedValue('report-1');

    expect(await sut().closePeriod(period)).toBe(1);
    expect(reports.create).toHaveBeenCalledTimes(1);
    expect(reports.create).toHaveBeenCalledWith(
      expect.objectContaining({ userId: 'u1', periodStart: period.periodStart, periodEnd: period.periodEnd }),
    );
  });

  it('closes the period for the given user only', async () => {
    reports.listBillableUsers.mockResolvedValue([
      { id: 'u1', sub: 's1', email: 'a@example.test' },
      { id: 'u2', sub: 's2', email: 'b@example.test' },
    ]);
    reports.getSamples.mockResolvedValue([
      { repositoryId: 'r', connectionType: 'immich', timestamp: period.periodStart, sizeBytes: MIB, objectCount: 1 },
    ]);
    reports.create.mockResolvedValue('report-1');

    expect(await sut().closePeriod(period, 's2')).toBe(1);
    expect(reports.getSamples).toHaveBeenCalledTimes(1);
    expect(reports.create).toHaveBeenCalledWith(expect.objectContaining({ userId: 'u2' }));
  });

  it('does not count an already closed period twice', async () => {
    reports.listBillableUsers.mockResolvedValue([{ id: 'u1', sub: 's1', email: 'a@example.test' }]);
    reports.getSamples.mockResolvedValue([
      { repositoryId: 'r', connectionType: 'immich', timestamp: period.periodStart, sizeBytes: MIB, objectCount: 1 },
    ]);
    reports.create.mockResolvedValue(null);

    expect(await sut().closePeriod(period)).toBe(0);
  });

  it('marks reports sent or not billable from the matching result', async () => {
    reports.listPending.mockResolvedValue([row('a', 'u1'), row('b', 'u2'), row('c', 'u3')]);
    futopay.report.mockResolvedValue([
      { usage_id: 'u1:2026-10-01T00:00:00.000Z', status: 'received', state: 'active' },
      { usage_id: 'u2:2026-10-01T00:00:00.000Z', status: 'not_billable', state: 'new' },
    ]);

    await sut().sendPending();

    expect(futopay.report).toHaveBeenCalledWith([
      expect.objectContaining({ usage_id: 'u1:2026-10-01T00:00:00.000Z', external_customer_id: 'sub-u1' }),
      expect.objectContaining({ usage_id: 'u2:2026-10-01T00:00:00.000Z' }),
      expect.objectContaining({ usage_id: 'u3:2026-10-01T00:00:00.000Z' }),
    ]);
    expect(reports.markSettled).toHaveBeenCalledWith('a', 'sent', expect.objectContaining({ status: 'received' }));
    expect(reports.markSettled).toHaveBeenCalledWith(
      'b',
      'not_billable',
      expect.objectContaining({ status: 'not_billable' }),
    );
    expect(reports.markFailed).toHaveBeenCalledWith(['c'], expect.any(String));
  });

  it('posts a pending row once when two sends overlap', async () => {
    reports.listPending.mockResolvedValue([row('a', 'u1')]);
    let release!: (value: any[]) => void;
    futopay.report.mockReturnValue(new Promise((resolve) => (release = resolve)));

    const service = sut();
    const first = service.sendPending();
    const second = service.sendPending();
    release([{ usage_id: 'u1:2026-10-01T00:00:00.000Z', status: 'received', state: 'active' }]);

    expect(await second).toBe(await first);
    expect(futopay.report).toHaveBeenCalledTimes(1);
    expect(reports.markSettled).toHaveBeenCalledTimes(1);
    // Once the send has finished, a new call sends again
    reports.listPending.mockResolvedValue([]);
    expect(await service.sendPending()).toEqual([]);
  });

  it('keeps every row pending when FUTO Pay is unreachable', async () => {
    reports.listPending.mockResolvedValue([row('a', 'u1')]);
    futopay.report.mockRejectedValue(new Error('connect ECONNREFUSED'));

    await expect(sut().sendPending()).rejects.toThrow('ECONNREFUSED');
    expect(reports.markFailed).toHaveBeenCalledWith(['a'], 'connect ECONNREFUSED');
    expect(reports.markSettled).not.toHaveBeenCalled();
  });
});
