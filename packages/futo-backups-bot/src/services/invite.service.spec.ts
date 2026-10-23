import { jest } from '@jest/globals';
import { ComponentId } from 'src/enum.js';
import { env } from 'src/env.js';
import { Messages } from 'src/messages.js';
import { InviteBatch } from 'src/repositories/yuccaApi.repository.js';
import { InviteService } from 'src/services/invite.service.js';
import { Mocks, newMocks } from '../../test/mocks.js';

const okInvite = { status: 'ok', code: 'token', expiresAt: new Date(Date.now() + 600_000), remaining: null } as const;
const newBatch = (overrides: Partial<InviteBatch> = {}): InviteBatch => ({
  id: 'batch-1',
  guildId: 'guild-1',
  channelId: 'channel-1',
  messageId: 'message-1',
  maxClaims: 5,
  remaining: 3,
  cancelledAt: null,
  createdByDiscordUserId: 'staff-1',
  ...overrides,
});

const claimButton = (call: unknown) =>
  (
    call as { components: { toJSON: () => { components: { disabled?: boolean; label?: string }[] } }[] }
  ).components[0].toJSON().components[0];

const newCommandInteraction = (options: Record<string, unknown>, overrides: object = {}) =>
  ({
    isButton: () => false,
    isModalSubmit: () => false,
    isChatInputCommand: () => true,
    commandName: 'beta-invite',
    user: { id: 'staff-1', username: 'Staffer' },
    guildId: 'guild-1',
    options: {
      getUser: jest.fn().mockReturnValue(options.user ?? null),
      getChannel: jest.fn().mockReturnValue(options.channel ?? null),
      getInteger: jest.fn().mockReturnValue(options.limit ?? null),
      getRole: jest.fn().mockReturnValue(options.mention ?? null),
    },
    replied: false,
    deferred: false,
    reply: jest.fn().mockResolvedValue(void 0),
    deferReply: jest.fn().mockResolvedValue(void 0),
    editReply: jest.fn().mockResolvedValue(void 0),
    member: { roles: ['staff-role'] as string[] },
    ...overrides,
  }) as never;

const newClaimInteraction = (overrides: object = {}) =>
  ({
    isButton: () => true,
    isModalSubmit: () => false,
    isChatInputCommand: () => false,
    customId: `${ComponentId.ClaimInvite}:batch-1`,
    user: { id: '123456789', username: 'Someone' },
    channelId: 'channel-1',
    message: { id: 'message-1', edit: jest.fn().mockResolvedValue(void 0) },
    replied: false,
    deferred: false,
    reply: jest.fn().mockResolvedValue(void 0),
    deferReply: jest.fn().mockResolvedValue(void 0),
    editReply: jest.fn().mockResolvedValue(void 0),
    ...overrides,
  }) as never;

describe(InviteService.name, () => {
  let sut: InviteService;
  let mocks: Mocks;
  const originalSecret = env.INTERNAL_SECRET;
  const originalGuild = env.DISCORD_GUILD_ID;

  beforeEach(() => {
    mocks = newMocks();
    sut = new InviteService(mocks.logger as never, mocks.discord as never, mocks.api as never);
    env.DISCORD_STAFF_ROLE_ID = 'staff-role';
    env.INTERNAL_SECRET = 'internal-test-secret';
    env.DISCORD_GUILD_ID = 'guild-1';
    mocks.api.getInviteBatch.mockResolvedValue(newBatch());
  });

  afterEach(() => {
    env.INTERNAL_SECRET = originalSecret;
    env.DISCORD_GUILD_ID = originalGuild;
  });

  describe('onInviteCommand', () => {
    it('refuses non-staff invokers', async () => {
      const interaction = newCommandInteraction({ user: { id: 'u1' } }, { member: { roles: [] as string[] } });

      await sut.onInviteCommand(interaction);

      expect((interaction as { reply: jest.Mock }).reply).toHaveBeenCalledWith(
        expect.objectContaining({ content: Messages.inviteStaffOnly }),
      );
      expect(mocks.api.createInvite).not.toHaveBeenCalled();
    });

    it('requires exactly one of user and channel', async () => {
      const both = newCommandInteraction({ user: { id: 'u1' }, channel: { id: 'c1' } });
      const neither = newCommandInteraction({});

      await sut.onInviteCommand(both);
      await sut.onInviteCommand(neither);

      for (const interaction of [both, neither]) {
        expect((interaction as { reply: jest.Mock }).reply).toHaveBeenCalledWith(
          expect.objectContaining({ content: Messages.invitePickOne }),
        );
      }
      expect(mocks.api.createInvite).not.toHaveBeenCalled();
    });

    it('DMs a personal invite link in user mode', async () => {
      mocks.api.createInvite.mockResolvedValue(okInvite);
      const interaction = newCommandInteraction({ user: { id: 'u1', username: 'target' } });

      await sut.onInviteCommand(interaction);

      expect(mocks.api.createInvite).toHaveBeenCalledWith('u1', 'target');
      expect(mocks.discord.sendDirectMessage).toHaveBeenCalledWith(
        'u1',
        expect.objectContaining({ content: Messages.inviteDm }),
      );
      expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith({
        content: Messages.inviteSent('u1'),
      });
    });

    it('hands the link to the invoker when the target has DMs closed', async () => {
      mocks.api.createInvite.mockResolvedValue(okInvite);
      mocks.discord.sendDirectMessage.mockResolvedValue(false);
      const interaction = newCommandInteraction({ user: { id: 'u1', username: 'target' } });

      await sut.onInviteCommand(interaction);

      expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith({
        content: expect.stringContaining('/login/invite?token=token'),
      });
    });

    it('reports an already-linked target', async () => {
      mocks.api.createInvite.mockResolvedValue({ status: 'already-linked' });
      const interaction = newCommandInteraction({ user: { id: 'u1', username: 'target' } });

      await sut.onInviteCommand(interaction);

      expect(mocks.discord.sendDirectMessage).not.toHaveBeenCalled();
      expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith({
        content: Messages.inviteAlreadyLinked('u1'),
      });
    });

    it('requires a limit in channel mode', async () => {
      const interaction = newCommandInteraction({ channel: { id: 'c1' } });

      await sut.onInviteCommand(interaction);

      expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith({
        content: Messages.inviteLimitRequired,
      });
      expect(mocks.api.createInviteBatch).not.toHaveBeenCalled();
    });

    it('posts a claim button and records the message id in channel mode', async () => {
      mocks.api.createInviteBatch.mockResolvedValue('batch-1');
      mocks.discord.sendMessage.mockResolvedValue({ id: 'message-1' } as never);
      const interaction = newCommandInteraction({ channel: { id: 'c1' }, limit: 10 });

      await sut.onInviteCommand(interaction);

      expect(mocks.api.createInviteBatch).toHaveBeenCalledWith('guild-1', 'c1', 10, 'staff-1');
      expect(mocks.discord.sendMessage).toHaveBeenCalledWith(
        'c1',
        expect.objectContaining({ content: Messages.inviteDrop(10, null, 'staff-1') }),
      );
      expect(mocks.api.setInviteBatchMessage).toHaveBeenCalledWith('batch-1', 'message-1');
      expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith({
        content: Messages.inviteDropPosted(10, 'c1'),
      });
    });

    it('mentions the everyone role as a literal @everyone', async () => {
      mocks.api.createInviteBatch.mockResolvedValue('batch-1');
      mocks.discord.sendMessage.mockResolvedValue({ id: 'message-1' } as never);
      const interaction = newCommandInteraction({ channel: { id: 'c1' }, limit: 2, mention: { id: 'guild-1' } });

      await sut.onInviteCommand(interaction);

      expect(mocks.discord.sendMessage).toHaveBeenCalledWith(
        'c1',
        expect.objectContaining({ content: Messages.inviteDrop(2, '@everyone', 'staff-1') }),
      );
    });

    it('mentions the requested role in the channel post', async () => {
      mocks.api.createInviteBatch.mockResolvedValue('batch-1');
      mocks.discord.sendMessage.mockResolvedValue({ id: 'message-1' } as never);
      const interaction = newCommandInteraction({ channel: { id: 'c1' }, limit: 5, mention: { id: 'role-1' } });

      await sut.onInviteCommand(interaction);

      expect(mocks.discord.sendMessage).toHaveBeenCalledWith(
        'c1',
        expect.objectContaining({ content: Messages.inviteDrop(5, '<@&role-1>', 'staff-1') }),
      );
    });
  });

  describe('closeDrop', () => {
    it('disables the drop button on the posted message', async () => {
      await sut.closeDrop('batch-1', 'channel-1', 'message-1');

      expect(mocks.discord.editMessage).toHaveBeenCalledWith(
        'channel-1',
        'message-1',
        expect.objectContaining({
          content: Messages.inviteDropEnded(5, 'staff-1'),
          components: [expect.anything()],
          allowedMentions: { parse: [] },
        }),
      );
    });
  });

  describe('onClaimInvite', () => {
    it('replies with a personal link on a successful claim', async () => {
      mocks.api.createInvite.mockResolvedValue({ ...okInvite, remaining: 3 });
      const interaction = newClaimInteraction();

      await sut.onClaimInvite(interaction);

      expect(mocks.api.createInvite).toHaveBeenCalledWith('123456789', 'Someone', 'batch-1');
      expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith(
        expect.objectContaining({ content: Messages.claimSuccess }),
      );
      expect((interaction as { message: { edit: jest.Mock } }).message.edit).not.toHaveBeenCalled();
      expect(mocks.api.getInviteBatch).toHaveBeenCalledWith('batch-1');
      expect(mocks.discord.editMessage).toHaveBeenCalledWith(
        'channel-1',
        'message-1',
        expect.objectContaining({ content: Messages.inviteDrop(5, null, 'staff-1', 3) }),
      );
    });

    it('disables the claim button when the last invite is claimed', async () => {
      mocks.api.createInvite.mockResolvedValue({ ...okInvite, remaining: 0 });
      mocks.api.getInviteBatch.mockResolvedValue(newBatch({ remaining: 0 }));
      const interaction = newClaimInteraction();

      await sut.onClaimInvite(interaction);

      expect(claimButton(mocks.discord.editMessage.mock.calls[0][2])).toEqual(
        expect.objectContaining({ disabled: true, label: Messages.inviteDropClaimedButton }),
      );
    });

    it('reports exhaustion and disables the button', async () => {
      mocks.api.createInvite.mockResolvedValue({ status: 'exhausted' });
      mocks.api.getInviteBatch.mockResolvedValue(newBatch({ remaining: 0 }));
      const interaction = newClaimInteraction();

      await sut.onClaimInvite(interaction);

      expect(claimButton(mocks.discord.editMessage.mock.calls[0][2]).disabled).toBe(true);
      expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith({
        content: Messages.claimExhausted,
      });
    });

    it('turns an already-linked claimer away', async () => {
      mocks.api.createInvite.mockResolvedValue({ status: 'already-linked' });
      const interaction = newClaimInteraction();

      await sut.onClaimInvite(interaction);

      expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith({
        content: Messages.claimAlreadyLinked,
      });
    });

    it('reports a cancelled drop and disables the button', async () => {
      mocks.api.createInvite.mockResolvedValue({ status: 'cancelled' });
      const interaction = newClaimInteraction();

      await sut.onClaimInvite(interaction);

      expect(claimButton(mocks.discord.editMessage.mock.calls[0][2])).toEqual(
        expect.objectContaining({ disabled: true, label: Messages.inviteDropEndedButton }),
      );
      expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith({
        content: Messages.claimDropEnded,
      });
    });

    it('reports a spent invite', async () => {
      mocks.api.createInvite.mockResolvedValue({ status: 'invite-used' });
      const interaction = newClaimInteraction();

      await sut.onClaimInvite(interaction);

      expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith({
        content: Messages.claimInviteUsed,
      });
    });

    it('uses authoritative availability rather than a stale claim response', async () => {
      mocks.api.createInvite.mockResolvedValue({ ...okInvite, remaining: 0 });
      mocks.api.getInviteBatch.mockResolvedValue(newBatch({ remaining: 2 }));

      await sut.onClaimInvite(newClaimInteraction());

      expect(mocks.discord.editMessage.mock.calls[0][2]).toEqual(
        expect.objectContaining({
          content: Messages.inviteDrop(5, null, 'staff-1', 2),
          allowedMentions: { parse: [] },
        }),
      );
      expect(claimButton(mocks.discord.editMessage.mock.calls[0][2]).disabled).toBe(false);
    });

    it('still delivers the personal link when availability lookup fails', async () => {
      mocks.api.createInvite.mockResolvedValue({ ...okInvite, remaining: 0 });
      mocks.api.getInviteBatch.mockRejectedValue(new Error('API unavailable'));
      const interaction = newClaimInteraction();

      await sut.onClaimInvite(interaction);

      expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith(
        expect.objectContaining({ content: Messages.claimSuccess }),
      );
      expect(mocks.discord.editMessage).not.toHaveBeenCalled();
      expect(mocks.logger.warn).toHaveBeenCalled();
    });

    it('refreshes availability even when the personal reply fails after the claim succeeds', async () => {
      mocks.api.createInvite.mockResolvedValue(okInvite);
      const interaction = newClaimInteraction({
        editReply: jest.fn<() => Promise<void>>().mockRejectedValue(new Error('interaction expired')),
      });

      await expect(sut.onClaimInvite(interaction)).rejects.toThrow('interaction expired');

      expect(mocks.api.getInviteBatch).toHaveBeenCalledWith('batch-1');
      expect(mocks.discord.editMessage).toHaveBeenCalledTimes(1);
    });

    it('refreshes the clicked message if its message id was not recorded', async () => {
      mocks.api.createInvite.mockResolvedValue(okInvite);
      mocks.api.getInviteBatch.mockResolvedValue(newBatch({ messageId: null }));

      await sut.onClaimInvite(newClaimInteraction());

      expect(mocks.discord.editMessage).toHaveBeenCalledWith('channel-1', 'message-1', expect.anything());
    });
  });

  describe('refreshDrops', () => {
    it('releases a stalled persistence lock after timeout so cancellation and later polls proceed', async () => {
      const controller = new AbortController();
      let markPersistenceStarted!: () => void;
      const persistenceStarted = new Promise<void>((resolve) => {
        markPersistenceStarted = resolve;
      });
      mocks.api.createInviteBatch.mockResolvedValue('batch-1');
      mocks.discord.sendMessage.mockResolvedValue({ id: 'message-1' } as never);
      mocks.api.setInviteBatchMessage
        .mockRejectedValueOnce(new Error('initial persistence unavailable'))
        .mockImplementationOnce(
          () =>
            new Promise<void>((_resolve, reject) => {
              controller.signal.addEventListener('abort', () => reject(controller.signal.reason as Error), {
                once: true,
              });
              markPersistenceStarted();
            }),
        );
      mocks.api.getInviteBatch.mockResolvedValue(newBatch({ messageId: null }));
      mocks.api.listInviteBatches.mockResolvedValue([]);
      await sut.onInviteCommand(newCommandInteraction({ channel: { id: 'channel-1' }, limit: 5 }));
      const polling = sut.refreshDrops();
      await persistenceStarted;
      const closing = sut.closeDrop('batch-1', 'channel-1', 'message-1');

      controller.abort(new DOMException('Persistence timed out', 'TimeoutError'));
      await Promise.all([polling, closing]);
      mocks.api.listInviteBatches.mockResolvedValue([newBatch({ id: 'batch-2' })]);
      mocks.api.getInviteBatch.mockResolvedValue(newBatch({ id: 'batch-2', messageId: 'message-2' }));
      await sut.refreshDrops();

      expect(mocks.api.setInviteBatchMessage).toHaveBeenCalledTimes(2);
      expect(claimButton(mocks.discord.editMessage.mock.calls[1][2]).label).toBe(Messages.inviteDropEndedButton);
      expect(mocks.discord.editMessage).toHaveBeenLastCalledWith('channel-1', 'message-2', expect.anything());
      expect(mocks.logger.warn).toHaveBeenCalledWith(
        expect.objectContaining({ name: 'TimeoutError' }),
        'could not record the invite drop message id',
      );
    });

    it('reopens a drop and repairs its message id after posting and claim-time persistence fail', async () => {
      mocks.api.createInviteBatch.mockResolvedValue('batch-1');
      mocks.discord.sendMessage.mockResolvedValue({ id: 'message-1' } as never);
      mocks.api.setInviteBatchMessage
        .mockRejectedValueOnce(new Error('post persistence unavailable'))
        .mockRejectedValueOnce(new Error('claim persistence unavailable'))
        .mockRejectedValueOnce(new Error('poll persistence unavailable'))
        .mockResolvedValue(void 0);
      mocks.api.listInviteBatches.mockResolvedValue([]);
      mocks.api.getInviteBatch.mockResolvedValue(newBatch({ messageId: null, remaining: 0 }));
      mocks.api.createInvite.mockResolvedValue({ ...okInvite, remaining: 0 });
      const interaction = newClaimInteraction();

      await sut.onInviteCommand(newCommandInteraction({ channel: { id: 'channel-1' }, limit: 5 }));
      await sut.onClaimInvite(interaction);
      expect(claimButton(mocks.discord.editMessage.mock.calls[0][2]).disabled).toBe(true);
      expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith(
        expect.objectContaining({ content: Messages.claimSuccess }),
      );
      mocks.api.getInviteBatch.mockResolvedValue(newBatch({ messageId: null, remaining: 1 }));

      await sut.refreshDrops();

      expect(mocks.discord.editMessage).toHaveBeenCalledTimes(2);
      expect(claimButton(mocks.discord.editMessage.mock.calls[1][2]).disabled).toBe(false);
      expect(mocks.discord.editMessage.mock.calls[1][2]).toEqual(
        expect.objectContaining({
          content: Messages.inviteDrop(5, null, 'staff-1', 1),
          allowedMentions: { parse: [] },
        }),
      );
      await sut.refreshDrops();
      await sut.refreshDrops();
      expect(mocks.api.setInviteBatchMessage).toHaveBeenCalledTimes(4);
      expect(mocks.api.setInviteBatchMessage).toHaveBeenLastCalledWith('batch-1', 'message-1');
      expect(mocks.api.getInviteBatch).toHaveBeenCalledTimes(3);
      expect(mocks.discord.editMessage).toHaveBeenCalledTimes(2);
    });

    it('repairs a clicked unrecorded message even when the batch-list request fails', async () => {
      mocks.api.createInvite.mockResolvedValue(okInvite);
      mocks.api.getInviteBatch.mockResolvedValue(newBatch({ messageId: null }));
      mocks.api.setInviteBatchMessage.mockRejectedValueOnce(new Error('persistence unavailable'));
      mocks.api.listInviteBatches.mockRejectedValueOnce(new Error('list unavailable')).mockResolvedValue([]);

      await sut.onClaimInvite(newClaimInteraction());
      await sut.refreshDrops();
      await sut.refreshDrops();

      expect(mocks.api.getInviteBatch).toHaveBeenCalledTimes(2);
      expect(mocks.api.setInviteBatchMessage).toHaveBeenCalledTimes(2);
      expect(mocks.api.setInviteBatchMessage).toHaveBeenLastCalledWith('batch-1', 'message-1');
      expect(mocks.discord.editMessage).toHaveBeenCalledTimes(1);
    });

    it.each([
      { name: 'missing', status: null },
      { name: 'cancelled', status: newBatch({ messageId: null, cancelledAt: new Date() }) },
    ])('forgets pending message persistence for a $name drop', async ({ status }) => {
      mocks.api.createInviteBatch.mockResolvedValue('batch-1');
      mocks.discord.sendMessage.mockResolvedValue({ id: 'message-1' } as never);
      mocks.api.setInviteBatchMessage.mockRejectedValue(new Error('persistence unavailable'));
      mocks.api.getInviteBatch.mockResolvedValue(status);
      mocks.api.listInviteBatches.mockResolvedValue([]);

      await sut.onInviteCommand(newCommandInteraction({ channel: { id: 'channel-1' }, limit: 5 }));
      await sut.refreshDrops();
      await sut.refreshDrops();

      expect(mocks.api.getInviteBatch).toHaveBeenCalledTimes(1);
      expect(mocks.api.setInviteBatchMessage).toHaveBeenCalledTimes(status ? 2 : 1);
      if (status) {
        expect(claimButton(mocks.discord.editMessage.mock.calls[0][2]).label).toBe(Messages.inviteDropEndedButton);
      } else {
        expect(mocks.discord.editMessage).not.toHaveBeenCalled();
      }
    });

    it('forgets a pending location when an authoritative lookup confirms it was already persisted', async () => {
      mocks.api.createInviteBatch.mockResolvedValue('batch-1');
      mocks.discord.sendMessage.mockResolvedValue({ id: 'message-1' } as never);
      mocks.api.setInviteBatchMessage.mockRejectedValueOnce(new Error('response lost after persistence'));
      mocks.api.listInviteBatches.mockResolvedValue([]);

      await sut.onInviteCommand(newCommandInteraction({ channel: { id: 'channel-1' }, limit: 5 }));
      await sut.refreshDrops();
      await sut.refreshDrops();

      expect(mocks.api.getInviteBatch).toHaveBeenCalledTimes(1);
      expect(mocks.api.setInviteBatchMessage).toHaveBeenCalledTimes(1);
      expect(mocks.discord.editMessage).toHaveBeenCalledTimes(1);
    });

    it('restores capacity after unused reservations expire and skips unchanged renders', async () => {
      mocks.api.listInviteBatches.mockResolvedValue([newBatch({ remaining: 0 })]);
      mocks.api.getInviteBatch
        .mockResolvedValueOnce(newBatch({ remaining: 0 }))
        .mockResolvedValue(newBatch({ remaining: 2 }));

      await sut.refreshDrops();
      await sut.refreshDrops();
      await sut.refreshDrops();

      expect(mocks.api.getInviteBatch).toHaveBeenCalledTimes(3);
      expect(mocks.discord.editMessage).toHaveBeenCalledTimes(2);
      expect(claimButton(mocks.discord.editMessage.mock.calls[0][2]).disabled).toBe(true);
      expect(claimButton(mocks.discord.editMessage.mock.calls[1][2])).toEqual(
        expect.objectContaining({ disabled: false, label: Messages.inviteDropButton }),
      );
      expect(mocks.discord.editMessage.mock.calls[1][2]).toEqual(
        expect.objectContaining({
          content: Messages.inviteDrop(5, null, 'staff-1', 2),
          allowedMentions: { parse: [] },
        }),
      );
    });

    it('keeps cancelled drops ended even when reservations later expire', async () => {
      mocks.api.listInviteBatches.mockResolvedValue([newBatch({ remaining: 0 })]);
      mocks.api.getInviteBatch.mockResolvedValueOnce(newBatch({ cancelledAt: new Date(), remaining: 2 }));

      await sut.refreshDrops();
      mocks.api.getInviteBatch.mockResolvedValue(newBatch({ remaining: 5 }));
      await sut.refreshDrops();

      expect(mocks.api.getInviteBatch).toHaveBeenCalledTimes(1);
      expect(mocks.discord.editMessage).toHaveBeenCalledTimes(1);
      expect(claimButton(mocks.discord.editMessage.mock.calls[0][2])).toEqual(
        expect.objectContaining({ disabled: true, label: Messages.inviteDropEndedButton }),
      );
      expect(mocks.discord.editMessage.mock.calls[0][2]).toEqual(
        expect.objectContaining({ content: Messages.inviteDropEnded(5, 'staff-1') }),
      );
    });

    it('does not refresh drops explicitly closed through the internal endpoint', async () => {
      mocks.api.listInviteBatches.mockResolvedValue([newBatch()]);

      await sut.closeDrop('batch-1', 'channel-1', 'message-1');
      await sut.refreshDrops();

      expect(mocks.api.getInviteBatch).toHaveBeenCalledTimes(1);
      expect(mocks.discord.editMessage).toHaveBeenCalledTimes(1);
      expect(claimButton(mocks.discord.editMessage.mock.calls[0][2]).label).toBe(Messages.inviteDropEndedButton);
    });

    it('retries failed Discord edits without changing the displayed availability state', async () => {
      mocks.api.listInviteBatches.mockResolvedValue([newBatch()]);
      mocks.discord.editMessage.mockRejectedValueOnce(new Error('Discord unavailable'));

      await sut.refreshDrops();
      await sut.refreshDrops();

      expect(mocks.discord.editMessage).toHaveBeenCalledTimes(2);
      expect(mocks.logger.warn).toHaveBeenCalled();
    });

    it('skips unconfigured integrations and other guilds', async () => {
      env.INTERNAL_SECRET = '';
      await sut.refreshDrops();
      env.INTERNAL_SECRET = 'configured';
      Object.defineProperty(mocks.discord, 'enabled', { value: false, configurable: true });
      await sut.refreshDrops();
      expect(mocks.api.listInviteBatches).not.toHaveBeenCalled();
      Object.defineProperty(mocks.discord, 'enabled', { value: true, configurable: true });
      mocks.api.listInviteBatches.mockResolvedValue([newBatch({ guildId: 'another-guild' })]);

      await sut.refreshDrops();

      expect(mocks.api.getInviteBatch).not.toHaveBeenCalled();
      expect(mocks.discord.editMessage).not.toHaveBeenCalled();
    });

    it('leaves existing controls unchanged when status or list requests fail', async () => {
      mocks.api.listInviteBatches.mockRejectedValueOnce(new Error('list unavailable'));
      await sut.refreshDrops();
      mocks.api.listInviteBatches.mockResolvedValue([newBatch()]);
      mocks.api.getInviteBatch.mockRejectedValueOnce(new Error('status unavailable'));

      await sut.refreshDrops();

      expect(mocks.discord.editMessage).not.toHaveBeenCalled();
      expect(mocks.logger.warn).toHaveBeenCalledTimes(2);
    });

    it('serializes claim and poll edits and fetches fresh counts after acquiring the lock', async () => {
      let releaseEdit!: () => void;
      let markEditStarted!: () => void;
      let markClaimReplied!: () => void;
      const blockedEdit = new Promise<void>((resolve) => {
        releaseEdit = resolve;
      });
      const editStarted = new Promise<void>((resolve) => {
        markEditStarted = resolve;
      });
      const claimReplied = new Promise<void>((resolve) => {
        markClaimReplied = resolve;
      });
      mocks.api.listInviteBatches.mockResolvedValue([newBatch({ remaining: 4 })]);
      mocks.api.getInviteBatch
        .mockResolvedValueOnce(newBatch({ remaining: 2 }))
        .mockResolvedValue(newBatch({ remaining: 1 }));
      mocks.discord.editMessage.mockImplementationOnce(async () => {
        markEditStarted();
        await blockedEdit;
      });
      mocks.api.createInvite.mockResolvedValue({ ...okInvite, remaining: 0 });
      const interaction = newClaimInteraction({
        editReply: jest.fn<() => Promise<void>>().mockImplementation(() => {
          markClaimReplied();
          return Promise.resolve();
        }),
      });
      const polling = sut.refreshDrops();
      await editStarted;
      const claiming = sut.onClaimInvite(interaction);
      await claimReplied;

      expect(mocks.api.getInviteBatch).toHaveBeenCalledTimes(1);
      expect(mocks.discord.editMessage).toHaveBeenCalledTimes(1);
      releaseEdit();
      await Promise.all([polling, claiming]);

      expect(mocks.api.getInviteBatch).toHaveBeenCalledTimes(2);
      expect(mocks.discord.editMessage.mock.calls[1][2]).toEqual(
        expect.objectContaining({ content: Messages.inviteDrop(5, null, 'staff-1', 1) }),
      );
      expect(claimButton(mocks.discord.editMessage.mock.calls[1][2]).disabled).toBe(false);
    });
  });
});
