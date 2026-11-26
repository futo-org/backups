import { jest } from '@jest/globals';
import { InviteMetricsService } from './inviteMetrics.service.js';

describe(InviteMetricsService.name, () => {
  const logger = { error: jest.fn() };
  const allowlist = { countInvites: jest.fn<() => Promise<unknown>>() };
  const inviteCodes = { countUses: jest.fn<() => Promise<unknown>>() };
  const gauges: Record<string, { record: jest.Mock }> = {};
  const metricService = {
    getGauge: jest.fn((name: string) => (gauges[name] = { record: jest.fn() })),
  };

  const service = () =>
    new InviteMetricsService(logger as never, allowlist as never, inviteCodes as never, metricService as never);

  beforeEach(() => {
    jest.clearAllMocks();
    allowlist.countInvites.mockResolvedValue([]);
    inviteCodes.countUses.mockResolvedValue([]);
  });

  it('records every source and state, zero-filling the missing ones', async () => {
    allowlist.countInvites.mockResolvedValue([
      { source: 'discord', state: 'used', count: 4 },
      { source: 'email', state: 'invited', count: 7 },
    ]);

    await service().sync();

    const gauge = gauges['beta_invites'];
    expect(gauge.record).toHaveBeenCalledTimes(9);
    expect(gauge.record).toHaveBeenCalledWith(4, { source: 'discord', state: 'used' });
    expect(gauge.record).toHaveBeenCalledWith(7, { source: 'email', state: 'invited' });
    expect(gauge.record).toHaveBeenCalledWith(0, { source: 'other', state: 'staged' });
  });

  it('records nothing when the count fails', async () => {
    allowlist.countInvites.mockRejectedValue(new Error('db down'));

    await service().sync();

    expect(gauges['beta_invites'].record).not.toHaveBeenCalled();
    expect(logger.error).toHaveBeenCalled();
  });

  it('records the uses and limit of each reusable invite code by name', async () => {
    inviteCodes.countUses.mockResolvedValue([
      { name: 'Immich meetup', uses: 12, maxUses: 50 },
      { name: 'Podcast', uses: 3, maxUses: null },
    ]);

    await service().sync();

    expect(gauges['beta_invite_code_uses'].record).toHaveBeenCalledWith(12, { name: 'Immich meetup' });
    expect(gauges['beta_invite_code_uses'].record).toHaveBeenCalledWith(3, { name: 'Podcast' });
    expect(gauges['beta_invite_code_max_uses'].record).toHaveBeenCalledTimes(1);
    expect(gauges['beta_invite_code_max_uses'].record).toHaveBeenCalledWith(50, { name: 'Immich meetup' });
  });

  it('still records allowlist invites when counting invite code uses fails', async () => {
    allowlist.countInvites.mockResolvedValue([{ source: 'discord', state: 'used', count: 4 }]);
    inviteCodes.countUses.mockRejectedValue(new Error('db down'));

    await service().sync();

    expect(gauges['beta_invites'].record).toHaveBeenCalledWith(4, { source: 'discord', state: 'used' });
    expect(gauges['beta_invite_code_uses'].record).not.toHaveBeenCalled();
    expect(logger.error).toHaveBeenCalled();
  });
});
