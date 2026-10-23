import { jest } from '@jest/globals';
import { Kysely, PostgresDialect } from 'kysely';
import { DB } from 'src/schema/index.js';
import { BetaInvitesRepository } from './betaInvites.repository.js';

describe(BetaInvitesRepository.name, () => {
  const mocks = {
    query: jest.fn<() => Promise<{ rows: { count: string }[] }>>(),
    release: jest.fn(),
  };
  let sut: BetaInvitesRepository;

  beforeEach(() => {
    jest.resetAllMocks();
    const db = new Kysely<DB>({
      dialect: new PostgresDialect({
        pool: {
          connect: jest.fn(() => Promise.resolve({ query: mocks.query, release: mocks.release })),
          end: jest.fn(),
        } as never,
      }),
    });
    sut = new BetaInvitesRepository(db);
  });

  describe('getBackedUpAccountCount', () => {
    it('counts non-FUTO accounts with at least one completed backup in their history', async () => {
      mocks.query.mockResolvedValue({ rows: [{ count: '12' }] });

      const count = await sut.getBackedUpAccountCount();

      expect(count).toBe(12);
      expect(mocks.query.mock.calls).toMatchSnapshot();
      expect(mocks.release).toHaveBeenCalledTimes(1);
    });

    it('returns zero when no invited account has completed a backup', async () => {
      mocks.query.mockResolvedValue({ rows: [{ count: '0' }] });

      expect(await sut.getBackedUpAccountCount()).toBe(0);
    });
  });
});
