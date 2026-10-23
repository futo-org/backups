import { jest } from '@jest/globals';
import { BetaInvitesRepository } from 'src/repositories/betaInvites.repository.js';
import { BetaInvitesService } from './betaInvites.service.js';

describe(BetaInvitesService.name, () => {
  const mocks = {
    logger: { error: jest.fn() },
    invites: { getBackedUpAccountCount: jest.fn<BetaInvitesRepository['getBackedUpAccountCount']>() },
    gauge: { record: jest.fn() },
    metrics: { getGauge: jest.fn() },
  };
  let sut: BetaInvitesService;

  beforeEach(() => {
    jest.resetAllMocks();
    mocks.metrics.getGauge.mockReturnValue(mocks.gauge);
    sut = new BetaInvitesService(mocks.logger as never, mocks.invites as never, mocks.metrics as never);
  });

  describe('sync', () => {
    it.each([0, 12])('records %i accounts with a completed backup', async (count) => {
      mocks.invites.getBackedUpAccountCount.mockResolvedValue(count);

      await sut.sync();

      expect(mocks.metrics.getGauge).toHaveBeenCalledWith('beta_invites_backed_up_accounts', {
        description: 'Non-FUTO accounts with at least one completed backup, assumed invited during beta',
      });
      expect(mocks.invites.getBackedUpAccountCount).toHaveBeenCalledTimes(1);
      expect(mocks.gauge.record).toHaveBeenCalledWith(count);
      expect(mocks.logger.error).not.toHaveBeenCalled();
    });

    it('logs a failed query without recording a false zero', async () => {
      const error = new Error('database unavailable');
      mocks.invites.getBackedUpAccountCount.mockRejectedValue(error);

      await sut.sync();

      expect(mocks.gauge.record).not.toHaveBeenCalled();
      expect(mocks.logger.error).toHaveBeenCalledWith(error, 'Failed to sync beta invite backup count');
    });
  });

  describe('onApplicationBootstrap', () => {
    it('records the count before the first scheduled sync', async () => {
      mocks.invites.getBackedUpAccountCount.mockResolvedValue(3);

      await sut.onApplicationBootstrap();

      expect(mocks.gauge.record).toHaveBeenCalledWith(3);
    });
  });
});
