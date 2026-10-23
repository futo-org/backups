import { NotFoundException } from '@nestjs/common';
import { Message } from 'discord.js';
import { env } from 'src/env.js';
import { InviteService } from 'src/services/invite.service.js';
import { SupportService } from 'src/services/support.service.js';
import { Mocks, newMocks } from '../../test/mocks.js';

const newMessage = (overrides: object = {}): Message =>
  ({
    id: 'message-1',
    guildId: 'guild',
    author: { id: 'customer-1', bot: false },
    channel: {
      id: 'ticket-1',
      name: 'ticket-customer',
      parentId: 'support-channel',
      archived: false,
      locked: false,
      isThread: () => true,
    },
    ...overrides,
  }) as never;

describe('support ticket context and activity', () => {
  let sut: SupportService;
  let mocks: Mocks;
  const originalSecret = env.INTERNAL_SECRET;

  beforeEach(() => {
    mocks = newMocks();
    env.INTERNAL_SECRET = 'context-test-secret';
    sut = new SupportService(
      mocks.logger as never,
      mocks.discord as never,
      mocks.api as never,
      new InviteService(mocks.logger as never, mocks.discord as never, mocks.api as never),
      mocks.freshdeskSync as never,
      mocks.columbo as never,
    );
  });

  afterEach(() => {
    env.INTERNAL_SECRET = originalSecret;
  });

  it('returns the recovered owner and includes mapping closure state', async () => {
    mocks.discord.getTicketContext.mockResolvedValue({
      ticketThreadId: 'ticket-1',
      discordUserId: 'customer-1',
      closed: false,
      messages: [],
    });
    mocks.api.getTicketByThread.mockResolvedValue({
      threadId: 'ticket-1',
      discordUserId: 'customer-1',
      closedAt: new Date(),
    } as never);

    await expect(sut.getTicketContext('ticket-1')).resolves.toEqual({
      ticketThreadId: 'ticket-1',
      discordUserId: 'customer-1',
      closed: true,
      messages: [],
    });
  });

  it('hides a missing Discord ticket context without looking up a mapping', async () => {
    mocks.discord.getTicketContext.mockResolvedValue(null);

    await expect(sut.getTicketContext('ticket-1')).rejects.toBeInstanceOf(NotFoundException);

    expect(mocks.api.getTicketByThread).not.toHaveBeenCalled();
  });

  it('returns trusted Discord context when the ticket has no mapping', async () => {
    const context = { ticketThreadId: 'ticket-1', discordUserId: 'customer-1', closed: false, messages: [] };
    mocks.discord.getTicketContext.mockResolvedValue(context);
    mocks.api.getTicketByThread.mockResolvedValue(null);

    await expect(sut.getTicketContext('ticket-1')).resolves.toEqual(context);

    expect(mocks.api.getTicketByThread).toHaveBeenCalledWith('ticket-1');
  });

  it.each([
    { threadId: 'another-ticket', discordUserId: 'customer-1' },
    { threadId: 'ticket-1', discordUserId: 'another-customer' },
  ])('hides mismatched ticket mappings with the same not-found status', async (mapping) => {
    mocks.discord.getTicketContext.mockResolvedValue({
      ticketThreadId: 'ticket-1',
      discordUserId: 'customer-1',
      closed: false,
      messages: [],
    });
    mocks.api.getTicketByThread.mockResolvedValue(mapping as never);

    await expect(sut.getTicketContext('ticket-1')).rejects.toBeInstanceOf(NotFoundException);
  });

  it('starts owner activity notification without waiting before Freshdesk synchronization', async () => {
    let release!: () => void;
    mocks.columbo.notifyTicketActivity.mockImplementationOnce(
      () =>
        new Promise<void>((resolve) => {
          release = resolve;
        }),
    );
    const message = newMessage();

    await sut.handleMessage(message);

    expect(mocks.columbo.notifyTicketActivity).toHaveBeenCalledWith('ticket-1', {
      authorId: 'customer-1',
      messageId: 'message-1',
    });
    expect(mocks.freshdeskSync.handleMessage).toHaveBeenCalledWith(message);
    expect(mocks.discord.getTicketOpening).not.toHaveBeenCalled();
    release();
  });

  it('logs notification failures while continuing Freshdesk synchronization', async () => {
    mocks.columbo.notifyTicketActivity.mockRejectedValueOnce(new Error('Columbo unavailable'));
    const message = newMessage();

    await sut.handleMessage(message);

    expect(mocks.freshdeskSync.handleMessage).toHaveBeenCalledWith(message);
    expect(mocks.logger.warn).toHaveBeenCalledWith(expect.any(Error), 'could not notify columbo of ticket activity');
  });

  it('keeps Freshdesk synchronization active when Columbo is unconfigured', async () => {
    Object.defineProperty(mocks.columbo, 'enabled', { value: false });
    const message = newMessage();

    await sut.handleMessage(message);

    expect(mocks.columbo.notifyTicketActivity).not.toHaveBeenCalled();
    expect(mocks.freshdeskSync.handleMessage).toHaveBeenCalledWith(message);
  });

  it.each([
    { author: { id: 'bot', bot: true } },
    { guildId: 'another-guild' },
    { channel: { isThread: () => false } },
    { channel: { isThread: () => true, parentId: 'another-parent', name: 'ticket-customer' } },
    { channel: { isThread: () => true, parentId: 'support-channel', name: 'staff-customer' } },
    { channel: { isThread: () => true, parentId: 'support-channel', name: 'ticket-customer', locked: true } },
  ])('only forwards qualifying customer-thread human activity', async (overrides) => {
    const message = newMessage(overrides);

    await sut.handleMessage(message);

    expect(mocks.columbo.notifyTicketActivity).not.toHaveBeenCalled();
    expect(mocks.freshdeskSync.handleMessage).toHaveBeenCalledWith(message);
  });

  it('wires the independent message handler during bootstrap', async () => {
    await sut.onApplicationBootstrap();
    const callback = mocks.discord.start.mock.calls[0][1]!;
    const message = newMessage();

    await callback(message);

    expect(mocks.columbo.notifyTicketActivity).toHaveBeenCalled();
    expect(mocks.freshdeskSync.handleMessage).toHaveBeenCalledWith(message);
  });
});
