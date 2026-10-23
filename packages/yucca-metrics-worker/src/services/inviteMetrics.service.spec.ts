import { jest } from '@jest/globals';
import { InviteMetricsService } from './inviteMetrics.service.js';

describe(InviteMetricsService.name, () => {
  const logger = { error: jest.fn() };
  const allowlist = { countInvites: jest.fn<() => Promise<unknown>>() };
  const gauge = { record: jest.fn() };
  const metricService = { getGauge: jest.fn(() => gauge) };

  const service = () => new InviteMetricsService(logger as never, allowlist as never, metricService as never);

  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('records every source and state, zero-filling the missing ones', async () => {
    allowlist.countInvites.mockResolvedValue([
      { source: 'discord', state: 'used', count: 4 },
      { source: 'email', state: 'invited', count: 7 },
    ]);

    await service().sync();

    expect(metricService.getGauge).toHaveBeenCalledWith('beta_invites', expect.anything());
    expect(gauge.record).toHaveBeenCalledTimes(9);
    expect(gauge.record).toHaveBeenCalledWith(4, { source: 'discord', state: 'used' });
    expect(gauge.record).toHaveBeenCalledWith(7, { source: 'email', state: 'invited' });
    expect(gauge.record).toHaveBeenCalledWith(0, { source: 'other', state: 'staged' });
  });

  it('records nothing when the count fails', async () => {
    allowlist.countInvites.mockRejectedValue(new Error('db down'));

    await service().sync();

    expect(gauge.record).not.toHaveBeenCalled();
    expect(logger.error).toHaveBeenCalled();
  });
});
