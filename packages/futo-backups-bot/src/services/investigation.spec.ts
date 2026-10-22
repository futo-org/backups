import { jest } from '@jest/globals';
import { ThreadChannel } from 'discord.js';
import { ComponentId } from 'src/enum.js';
import { Messages } from 'src/messages.js';
import { InviteService } from 'src/services/invite.service.js';
import { SupportService } from 'src/services/support.service.js';
import { Mocks, newMocks } from '../../test/mocks.js';

const asThread = (properties: object) =>
  Object.assign(Object.create(ThreadChannel.prototype) as ThreadChannel, properties);
const newInteraction = (kind: 'button' | 'command' | 'modal', overrides: object = {}) =>
  ({
    isButton: () => kind === 'button',
    isModalSubmit: () => kind === 'modal',
    isChatInputCommand: () => kind === 'command',
    customId: kind === 'modal' ? ComponentId.InvestigationModal : ComponentId.Investigate,
    commandName: 'investigate',
    guildId: 'guild',
    user: { id: 'staff-1', username: 'Staff' },
    member: { roles: ['staff-role'] },
    channel: asThread({ id: 'staff-1', name: 'staff-someone-6789-x', parentId: 'support-channel', locked: false }),
    options: { getString: () => 'Check the restore error' },
    fields: { getTextInputValue: () => 'Check the restore error' },
    reply: jest.fn<() => Promise<void>>().mockResolvedValue(),
    deferReply: jest.fn(),
    editReply: jest.fn<() => Promise<void>>().mockResolvedValue(),
    showModal: jest.fn(),
    deferred: false,
    replied: false,
    ...overrides,
  }) as never;

describe('staff investigations', () => {
  let sut: SupportService;
  let mocks: Mocks;

  beforeEach(() => {
    mocks = newMocks();
    sut = new SupportService(
      mocks.logger as never,
      mocks.discord as never,
      mocks.api as never,
      new InviteService(mocks.logger as never, mocks.discord as never, mocks.api as never),
      mocks.freshdeskSync as never,
      mocks.columbo as never,
    );
    mocks.discord.findSupportThreadByName.mockResolvedValue(
      asThread({ id: 'ticket-1', name: 'ticket-someone-6789-x', locked: false }) as never,
    );
    mocks.discord.getTicketOpening.mockResolvedValue({
      discordUserId: '123456789',
      description: 'Original backup issue',
    });
    mocks.api.getLink.mockResolvedValue({ userId: 'user-1', discordUserId: '123456789', discordUsername: 'someone' });
  });

  it.each(['button', 'command', 'modal'] as const)('refuses non-staff %s requests', async (kind) => {
    const interaction = newInteraction(kind, { member: { roles: [] } });

    await sut.handleInteraction(interaction);

    expect(mocks.columbo.requestInvestigation).not.toHaveBeenCalled();
    expect((interaction as { reply: jest.Mock }).reply).toHaveBeenCalledWith(
      expect.objectContaining({ content: expect.stringContaining('Only staff') }),
    );
  });

  it('opens an optional extra-prompt modal from the button', async () => {
    const interaction = newInteraction('button');

    await sut.handleInteraction(interaction);

    expect((interaction as { showModal: jest.Mock }).showModal).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ custom_id: ComponentId.InvestigationModal }) }),
    );
    expect(mocks.columbo.requestInvestigation).not.toHaveBeenCalled();
  });

  it('opens the same modal when the command has no prompt', async () => {
    const interaction = newInteraction('command', { options: { getString: () => null } });

    await sut.handleInteraction(interaction);

    expect((interaction as { showModal: jest.Mock }).showModal).toHaveBeenCalled();
  });

  it.each(['command', 'modal'] as const)(
    'queues a %s request with original issue and recent customer conversation',
    async (kind) => {
      mocks.discord.listThreadMessages.mockResolvedValue([
        {
          author: { bot: false, username: 'someone' },
          createdAt: new Date('2026-10-22T12:00:00Z'),
          content: 'Restore fails',
          attachments: new Map([['a', { url: 'https://cdn.test/error.png' }]]),
        } as never,
        { author: { bot: true }, content: 'Previous LLM result' } as never,
      ]);

      await sut.handleInteraction(newInteraction(kind));

      expect(mocks.discord.findSupportThreadByName).toHaveBeenCalledWith('ticket-someone-6789-x');
      expect(mocks.columbo.requestInvestigation).toHaveBeenCalledWith({
        ticketThreadId: 'ticket-1',
        staffThreadId: 'staff-1',
        discordUserId: '123456789',
        username: 'someone',
        userId: 'user-1',
        description: 'Original backup issue',
        prompt: 'Check the restore error',
        requestedBy: 'staff-1',
        conversation: '2026-10-22T12:00:00.000Z someone: Restore fails\nhttps://cdn.test/error.png',
      });
      expect(mocks.discord.sendToThread).toHaveBeenCalledWith(
        'staff-1',
        expect.objectContaining({ allowedMentions: { parse: [] } }),
      );
    },
  );

  it('allows a retry with no additional prompt', async () => {
    await sut.handleInteraction(newInteraction('modal', { fields: { getTextInputValue: () => ' ' } }));

    expect(mocks.columbo.requestInvestigation).toHaveBeenCalledWith(
      expect.objectContaining({ prompt: '', requestedBy: 'staff-1' }),
    );
  });

  it('acknowledges a queued investigation when its staff announcement fails', async () => {
    mocks.discord.sendToThread.mockRejectedValueOnce(new Error('Discord unavailable'));
    const interaction = newInteraction('command');

    await sut.handleInteraction(interaction);

    expect(mocks.columbo.requestInvestigation).toHaveBeenCalledTimes(1);
    expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith({
      content: Messages.investigationQueued,
    });
    expect((interaction as { reply: jest.Mock }).reply).not.toHaveBeenCalled();
    expect(mocks.logger.warn).toHaveBeenCalledWith(expect.any(Error), 'could not announce the queued investigation');
  });

  it('includes recent email evidence mirrored into Discord', async () => {
    mocks.discord.listThreadMessages.mockResolvedValue([
      {
        author: { bot: true },
        createdAt: new Date('2026-10-22T12:00:00Z'),
        embeds: [{ author: { name: 'Customer (via email)' }, description: 'New error from email' }],
        attachments: new Map(),
      } as never,
    ]);

    await sut.handleInteraction(newInteraction('command'));

    expect(mocks.columbo.requestInvestigation).toHaveBeenCalledWith(
      expect.objectContaining({ conversation: '2026-10-22T12:00:00.000Z Customer (via email): New error from email' }),
    );
  });

  it('uses the ticket account even if the Discord user has since relinked', async () => {
    mocks.api.getTicketByThread.mockResolvedValue({
      userId: 'original-account',
      staffThreadId: 'staff-1',
      threadId: 'ticket-1',
    } as never);
    mocks.discord.getThreadById.mockResolvedValue(asThread({ id: 'ticket-1', locked: false }) as never);

    await sut.handleInteraction(newInteraction('command'));

    expect(mocks.api.getLink).not.toHaveBeenCalled();
    expect(mocks.discord.findSupportThreadByName).not.toHaveBeenCalled();
    expect(mocks.columbo.requestInvestigation).toHaveBeenCalledWith(
      expect.objectContaining({ userId: 'original-account' }),
    );
  });

  it('refuses a closed ticket mapping', async () => {
    mocks.api.getTicketByThread.mockResolvedValue({ closedAt: new Date() } as never);

    await sut.handleInteraction(newInteraction('command'));

    expect(mocks.columbo.requestInvestigation).not.toHaveBeenCalled();
  });

  it('refuses a ticket without an account', async () => {
    mocks.api.getLink.mockResolvedValue(null);

    await sut.handleInteraction(newInteraction('command'));

    expect(mocks.columbo.requestInvestigation).not.toHaveBeenCalled();
  });

  it.each(['missing', 'locked', 'opening'] as const)('refuses %s original ticket context', async (state) => {
    if (state === 'missing') {
      mocks.discord.findSupportThreadByName.mockResolvedValue(undefined);
    } else if (state === 'locked') {
      mocks.discord.findSupportThreadByName.mockResolvedValue(asThread({ id: 'ticket-1', locked: true }) as never);
    } else {
      mocks.discord.getTicketOpening.mockResolvedValue(null);
    }

    await sut.handleInteraction(newInteraction('command'));

    expect(mocks.columbo.requestInvestigation).not.toHaveBeenCalled();
  });

  it.each([
    null,
    asThread({ name: 'staff-x', parentId: 'other-channel', locked: false }),
    asThread({ name: 'ticket-x', parentId: 'support-channel', locked: false }),
    asThread({ name: 'staff-x', parentId: 'support-channel', locked: true }),
  ])('refuses requests outside an open staff thread', async (channel) => {
    await sut.handleInteraction(newInteraction('command', { channel }));

    expect(mocks.columbo.requestInvestigation).not.toHaveBeenCalled();
    expect(mocks.discord.getTicketOpening).not.toHaveBeenCalled();
  });

  it('reports unconfigured investigations', async () => {
    Object.defineProperty(mocks.columbo, 'enabled', { value: false });

    await sut.handleInteraction(newInteraction('command'));

    expect(mocks.columbo.requestInvestigation).not.toHaveBeenCalled();
  });

  it('reports queue failure without claiming that an investigation started', async () => {
    mocks.columbo.requestInvestigation.mockRejectedValue(new Error('queue full'));
    const interaction = newInteraction('command');

    await sut.handleInteraction(interaction);

    expect(mocks.discord.sendToThread).not.toHaveBeenCalled();
    expect((interaction as { editReply: jest.Mock }).editReply).not.toHaveBeenCalledWith(
      expect.objectContaining({ content: expect.stringContaining('queued') }),
    );
  });

  it('bounds the recent conversation sent to Columbo', async () => {
    mocks.discord.listThreadMessages.mockResolvedValue([
      {
        author: { bot: false, username: 'someone' },
        createdAt: new Date(),
        content: 'x'.repeat(20_000),
        attachments: new Map(),
      } as never,
    ]);

    await sut.handleInteraction(newInteraction('command'));

    expect(mocks.columbo.requestInvestigation.mock.calls[0][0].conversation).toHaveLength(16_000);
  });
});
