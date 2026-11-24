import { NotFoundException } from '@nestjs/common';
import { NoResultError } from 'kysely';
import { UserService } from 'src/services/user.service.js';
import { Mocks, newMocks } from '../../test/mocks.js';

describe(UserService.name, () => {
  let sut: UserService;
  let mocks: Mocks;

  const user = { id: 'user-1', sub: 'sub-1', name: 'Someone', email: 'someone@example.test', disabled: false };
  const link = {
    id: 'link-1',
    userId: 'user-1',
    discordUserId: '123456789',
    discordUsername: 'someone',
    createdAt: new Date('2026-08-26T00:00:00.000Z'),
  };

  beforeEach(() => {
    mocks = newMocks();
    sut = new UserService(mocks.user as never, mocks.session as never, mocks.discordLink as never);
  });

  describe('get', () => {
    it('includes the discord link', async () => {
      mocks.user.get.mockResolvedValue(user as never);
      mocks.discordLink.getByUserId.mockResolvedValue(link);

      await expect(sut.get('user-1')).resolves.toEqual({
        user,
        discordLink: { discordUserId: '123456789', discordUsername: 'someone', createdAt: link.createdAt },
      });
    });

    it('returns a null link for unlinked users', async () => {
      mocks.user.get.mockResolvedValue(user as never);
      mocks.discordLink.getByUserId.mockResolvedValue(void 0);

      await expect(sut.get('user-1')).resolves.toEqual({ user, discordLink: null });
    });

    it('rejects an unknown user', async () => {
      mocks.user.get.mockRejectedValue(new NoResultError({} as never));
      mocks.discordLink.getByUserId.mockResolvedValue(void 0);

      await expect(sut.get('user-1')).rejects.toBeInstanceOf(NotFoundException);
    });

    it('rethrows other errors', async () => {
      const error = new Error('connection refused');
      mocks.user.get.mockRejectedValue(error);
      mocks.discordLink.getByUserId.mockResolvedValue(void 0);

      await expect(sut.get('user-1')).rejects.toBe(error);
    });
  });

  describe('linkDiscord', () => {
    it('links after verifying the user exists', async () => {
      mocks.user.get.mockResolvedValue(user as never);
      mocks.discordLink.link.mockResolvedValue(link);

      await expect(sut.linkDiscord('user-1', { discordUserId: '123456789' })).resolves.toEqual({
        discordUserId: '123456789',
        discordUsername: 'someone',
        createdAt: link.createdAt,
      });

      expect(mocks.discordLink.link).toHaveBeenCalledWith('user-1', '123456789', '');
    });

    it('rejects an unknown user without linking', async () => {
      mocks.user.get.mockRejectedValue(new NoResultError({} as never));

      await expect(sut.linkDiscord('user-1', { discordUserId: '123456789' })).rejects.toBeInstanceOf(NotFoundException);

      expect(mocks.discordLink.link).not.toHaveBeenCalled();
    });
  });

  describe('unlinkDiscord', () => {
    it('rejects when no link exists', async () => {
      mocks.discordLink.unlink.mockResolvedValue(false);

      await expect(sut.unlinkDiscord('user-1')).rejects.toBeInstanceOf(NotFoundException);
    });

    it('removes an existing link', async () => {
      mocks.discordLink.unlink.mockResolvedValue(true);

      await expect(sut.unlinkDiscord('user-1')).resolves.toBeUndefined();
    });
  });
});
