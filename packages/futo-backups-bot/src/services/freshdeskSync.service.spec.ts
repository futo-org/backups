import { jest } from '@jest/globals';
import { FreshdeskSyncService } from 'src/services/freshdeskSync.service.js';
import { Mocks, newMocks } from '../../test/mocks.js';

const mapping = {
  id: 'map-1',
  threadId: 'thread-1',
  staffThreadId: 'staff-1',
  freshdeskTicketId: '42',
  discordUserId: 'cust',
  userId: 'user-1',
  emailSubscribed: false,
  lastMirroredMessageId: 'seed',
  lastStaffMirroredMessageId: 'staff-seed',
  lastFreshdeskConversationId: null,
  closedAt: null,
};

const summary = {
  id: 'user-1',
  name: 'Someone',
  email: 'someone@example.test',
  createdAt: new Date('2026-01-01T00:00:00.000Z'),
  connectionCount: 1,
  repositoryCount: 2,
  lastSeenAt: null,
};

const imageStub = { name: 'error.png', url: 'https://cdn.discord.test/error.png' };
const freshdeskImageStub = { name: 'solution.png', attachment_url: 'https://example.freshdesk.test/solution.png' };
const discordAttachmentLimit = 8 * 1024 * 1024;

const msg = (id: string, authorId: string, overrides: object = {}) =>
  ({
    id,
    author: { id: authorId, bot: false, username: `user-${authorId}` },
    content: `message ${id}`,
    attachments: new Map(),
    ...overrides,
  }) as never;

const imageMsg = (id: string, authorId: string) =>
  msg(id, authorId, { content: '', attachments: new Map([['image', imageStub]]) });

const inThread = (message: object, channelId: string) =>
  ({
    ...message,
    channel: { isThread: () => true, parentId: 'support-channel', id: channelId },
  }) as never;

const conversation = (id: number, overrides: object = {}) => ({
  id,
  body_text: `conversation ${id}`,
  user_id: 9,
  private: false,
  incoming: false,
  attachments: [],
  ...overrides,
});

const newInteraction = (overrides: object = {}) =>
  ({
    channelId: 'thread-1',
    user: { id: 'cust', username: 'someone' },
    reply: jest.fn(),
    deferReply: jest.fn(),
    editReply: jest.fn(),
    ...overrides,
  }) as never;

const staffInteraction = (overrides: object = {}) =>
  newInteraction({ user: { id: 'staff', username: 'staffer' }, member: { roles: ['staff-role'] }, ...overrides });

describe(FreshdeskSyncService.name, () => {
  let sut: FreshdeskSyncService;
  let mocks: Mocks;

  beforeEach(() => {
    mocks = newMocks();
    sut = new FreshdeskSyncService(
      mocks.logger as never,
      mocks.discord as never,
      mocks.freshdesk as never,
      mocks.api as never,
    );
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  describe('onTicketOpened', () => {
    it('creates the freshdesk ticket with a dummy requester and registers the mapping', async () => {
      mocks.freshdesk.createTicket.mockResolvedValue('42');
      mocks.api.createTicketMapping.mockResolvedValue(mapping);

      await sut.onTicketOpened({
        threadId: 'thread-1',
        seedMessageId: 'seed',
        staffThreadId: 'staff-1',
        staffSeedMessageId: 'staff-seed',
        discordUserId: 'cust',
        username: 'someone',
        userId: 'user-1',
        description: 'backups fail\nwith an error',
        staffNote: 'account context',
      });

      expect(mocks.freshdesk.createTicket).toHaveBeenCalledWith({
        email: 'cust@no.futo.org',
        name: 'someone',
        subject: '[Discord] someone: backups fail',
        description: 'backups fail<br>with an error',
      });
      expect(mocks.api.createTicketMapping).toHaveBeenCalledWith({
        threadId: 'thread-1',
        staffThreadId: 'staff-1',
        freshdeskTicketId: '42',
        discordUserId: 'cust',
        userId: 'user-1',
        lastMirroredMessageId: 'seed',
        lastStaffMirroredMessageId: 'staff-seed',
      });
      expect(mocks.freshdesk.createNote).toHaveBeenCalledWith('42', expect.stringContaining('account context'), {
        private: true,
      });
    });
  });

  describe('handleMessage', () => {
    it('mirrors image-only customer messages as incoming public notes', async () => {
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.discord.fetchMessagesAfter.mockResolvedValue([imageMsg('m1', 'cust')]);

      await sut.handleMessage(inThread(imageMsg('m1', 'cust'), 'thread-1'));

      expect(mocks.freshdesk.createNote).toHaveBeenCalledWith(
        '42',
        '<b>user-cust</b> (Discord):<br><i>(attachment)</i>',
        { private: false, incoming: true },
        [imageStub],
      );
      expect(mocks.freshdesk.createReply).not.toHaveBeenCalled();
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastMirroredMessageId: 'm1' });
    });

    it('mirrors image-only staff messages as outgoing replies after the debounce', async () => {
      jest.useFakeTimers();
      try {
        mocks.api.getTicketByThread.mockResolvedValue(mapping);
        mocks.discord.fetchMessagesAfter.mockResolvedValue([imageMsg('m1', 'staff')]);

        await sut.handleMessage(inThread(imageMsg('m1', 'staff'), 'thread-1'));
        await jest.advanceTimersByTimeAsync(120_000);

        expect(mocks.freshdesk.createReply).toHaveBeenCalledWith('42', '<b>user-staff</b>:<br><i>(attachment)</i>', [
          imageStub,
        ]);
        expect(mocks.freshdesk.createNote).not.toHaveBeenCalled();
        expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastMirroredMessageId: 'm1' });
      } finally {
        jest.useRealTimers();
      }
    });

    it('keeps image-only staff-thread messages private', async () => {
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.discord.fetchMessagesAfter.mockResolvedValue([imageMsg('s1', 'staff')]);

      await sut.handleMessage(inThread(imageMsg('s1', 'staff'), 'staff-1'));

      expect(mocks.freshdesk.createNote).toHaveBeenCalledWith(
        '42',
        '<b>user-staff</b> (staff notes):<br><i>(attachment)</i>',
        { private: true },
        [imageStub],
      );
      expect(mocks.freshdesk.createReply).not.toHaveBeenCalled();
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastStaffMirroredMessageId: 's1' });
    });

    it('retains the cursor after failed uploads and retries the image on the next poll', async () => {
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.discord.fetchMessagesAfter.mockImplementation((threadId) =>
        Promise.resolve(threadId === 'thread-1' ? [imageMsg('m1', 'cust')] : []),
      );
      mocks.freshdesk.createNote.mockRejectedValueOnce(new TypeError('upload failed'));
      mocks.api.listOpenTickets.mockResolvedValue([mapping]);

      await sut.handleMessage(inThread(imageMsg('m1', 'cust'), 'thread-1'));

      expect(mocks.api.updateTicket).not.toHaveBeenCalled();
      expect(mocks.logger.error).toHaveBeenCalledWith(
        expect.any(TypeError),
        'failed to mirror a discord message to freshdesk',
      );

      await sut.poll();

      expect(mocks.freshdesk.createNote).toHaveBeenCalledTimes(2);
      expect(mocks.freshdesk.createNote).toHaveBeenLastCalledWith(
        '42',
        expect.stringContaining('(attachment)'),
        { private: false, incoming: true },
        [imageStub],
      );
      expect(mocks.api.updateTicket).toHaveBeenCalledTimes(1);
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastMirroredMessageId: 'm1' });
    });

    it('mirrors buffered staff messages and the customer message in order', async () => {
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.discord.fetchMessagesAfter.mockResolvedValue([msg('m1', 'staff'), msg('m2', 'cust')]);

      await sut.handleMessage(inThread(msg('m2', 'cust'), 'thread-1'));

      expect(mocks.freshdesk.createReply).toHaveBeenCalledWith('42', expect.stringContaining('user-staff'), []);
      expect(mocks.freshdesk.createNote).toHaveBeenCalledWith(
        '42',
        expect.stringContaining('user-cust'),
        { private: false, incoming: true },
        [],
      );
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastMirroredMessageId: 'm1' });
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastMirroredMessageId: 'm2' });
    });

    it('holds back a trailing staff group until the debounce fires', async () => {
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.discord.fetchMessagesAfter.mockResolvedValue([msg('m1', 'cust'), msg('m2', 'staff')]);

      await sut.handleMessage(inThread(msg('m1', 'cust'), 'thread-1'));

      expect(mocks.freshdesk.createNote).toHaveBeenCalledTimes(1);
      expect(mocks.freshdesk.createReply).not.toHaveBeenCalled();
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastMirroredMessageId: 'm1' });
      expect(mocks.api.updateTicket).not.toHaveBeenCalledWith('map-1', { lastMirroredMessageId: 'm2' });
    });

    it('debounces staff messages into one combined reply', async () => {
      jest.useFakeTimers();
      try {
        mocks.api.getTicketByThread.mockResolvedValue(mapping);
        mocks.discord.fetchMessagesAfter.mockResolvedValue([msg('m1', 'staff-a'), msg('m2', 'staff-b')]);

        await sut.handleMessage(inThread(msg('m1', 'staff-a'), 'thread-1'));
        await sut.handleMessage(inThread(msg('m2', 'staff-b'), 'thread-1'));
        expect(mocks.freshdesk.createReply).not.toHaveBeenCalled();

        await jest.advanceTimersByTimeAsync(120_000);

        expect(mocks.freshdesk.createReply).toHaveBeenCalledTimes(1);
        expect(mocks.freshdesk.createReply).toHaveBeenCalledWith('42', expect.stringContaining('user-staff-a'), []);
        expect(mocks.freshdesk.createReply).toHaveBeenCalledWith('42', expect.stringContaining('user-staff-b'), []);
      } finally {
        jest.useRealTimers();
      }
    });

    it('mirrors staff-thread messages as private notes', async () => {
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.discord.fetchMessagesAfter.mockResolvedValue([msg('s1', 'staff')]);

      await sut.handleMessage(inThread(msg('s1', 'staff'), 'staff-1'));

      expect(mocks.discord.fetchMessagesAfter).toHaveBeenCalledWith('staff-1', 'staff-seed');
      expect(mocks.freshdesk.createNote).toHaveBeenCalledWith(
        '42',
        expect.stringContaining('staff notes'),
        { private: true },
        [],
      );
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastStaffMirroredMessageId: 's1' });
    });

    it('ignores threads without a mapping', async () => {
      mocks.api.getTicketByThread.mockResolvedValue(null);

      await sut.handleMessage(inThread(msg('m1', 'cust'), 'thread-9'));

      expect(mocks.freshdesk.createNote).not.toHaveBeenCalled();
      expect(mocks.freshdesk.createReply).not.toHaveBeenCalled();
    });
  });

  describe('onFreshdeskPing', () => {
    it('posts image-only Freshdesk conversations with the downloaded image bytes', async () => {
      jest
        .spyOn(globalThis, 'fetch')
        .mockResolvedValueOnce(
          new Response(Uint8Array.from([137, 80, 78, 71]), { headers: { 'Content-Type': 'image/png' } }),
        );
      mocks.api.getTicketByFreshdeskId.mockResolvedValue(mapping);
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.freshdesk.listConversationsAfter.mockResolvedValue([
        conversation(5, { body_text: null, attachments: [freshdeskImageStub] }),
      ] as never);

      await sut.onFreshdeskPing('42');

      expect(mocks.discord.sendToThread).toHaveBeenCalledWith('thread-1', {
        embeds: [expect.objectContaining({ data: expect.objectContaining({ description: '(attachment)' }) })],
        files: [expect.objectContaining({ name: 'solution.png', attachment: Buffer.from([137, 80, 78, 71]) })],
      });
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastFreshdeskConversationId: '5' });
    });

    it('retries Freshdesk images after download failures without advancing the cursor', async () => {
      const ctx = { error: new TypeError('download failed') };
      jest
        .spyOn(globalThis, 'fetch')
        .mockRejectedValueOnce(ctx.error)
        .mockResolvedValueOnce(new Response(Uint8Array.from([137, 80, 78, 71])));
      mocks.api.getTicketByFreshdeskId.mockResolvedValue(mapping);
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.freshdesk.listConversationsAfter.mockResolvedValue([
        conversation(5, { body_text: '', attachments: [freshdeskImageStub] }),
      ] as never);

      await expect(sut.onFreshdeskPing('42')).rejects.toBe(ctx.error);

      expect(mocks.discord.sendToThread).not.toHaveBeenCalled();
      expect(mocks.api.updateTicket).not.toHaveBeenCalled();

      await sut.onFreshdeskPing('42');

      expect(mocks.discord.sendToThread).toHaveBeenCalledTimes(1);
      expect(mocks.discord.sendToThread).toHaveBeenCalledWith(
        'thread-1',
        expect.objectContaining({
          files: [expect.objectContaining({ name: 'solution.png', attachment: Buffer.from([137, 80, 78, 71]) })],
        }),
      );
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastFreshdeskConversationId: '5' });
    });

    it('retries an old Freshdesk image after a restart without a recent ticket update', async () => {
      jest
        .spyOn(globalThis, 'fetch')
        .mockRejectedValueOnce(new TypeError('attachment unavailable'))
        .mockResolvedValueOnce(new Response(Uint8Array.from([137, 80, 78, 71])));
      mocks.api.getTicketByFreshdeskId.mockResolvedValue(mapping);
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.api.listOpenTickets.mockResolvedValue([mapping]);
      mocks.freshdesk.listUpdatedTicketIds.mockResolvedValue([]);
      mocks.freshdesk.listConversationsAfter.mockResolvedValue([
        conversation(5, { body_text: '', attachments: [freshdeskImageStub] }),
      ] as never);
      await expect(sut.onFreshdeskPing('42')).rejects.toThrow('attachment unavailable');
      expect(mocks.api.updateTicket).not.toHaveBeenCalled();
      jest.spyOn(Date, 'now').mockReturnValue(Date.now() + 20 * 60_000);
      const restarted = new FreshdeskSyncService(
        mocks.logger as never,
        mocks.discord as never,
        mocks.freshdesk as never,
        mocks.api as never,
      );

      await restarted.poll();

      expect(mocks.discord.sendToThread).toHaveBeenCalledTimes(1);
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastFreshdeskConversationId: '5' });
    });

    it('does not post partial images when another Freshdesk attachment returns an HTTP error', async () => {
      jest
        .spyOn(globalThis, 'fetch')
        .mockResolvedValueOnce(new Response(Uint8Array.from([137, 80, 78, 71])))
        .mockResolvedValueOnce(new Response('Unavailable', { status: 503 }));
      mocks.api.getTicketByFreshdeskId.mockResolvedValue(mapping);
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.freshdesk.listConversationsAfter.mockResolvedValue([
        conversation(5, {
          attachments: [
            freshdeskImageStub,
            { name: 'second.png', attachment_url: 'https://example.freshdesk.test/second.png' },
          ],
        }),
      ] as never);

      await expect(sut.onFreshdeskPing('42')).rejects.toThrow('503');

      expect(mocks.discord.sendToThread).not.toHaveBeenCalled();
      expect(mocks.api.updateTicket).not.toHaveBeenCalled();
    });

    it('retains the Freshdesk cursor when an image stream is interrupted', async () => {
      const ctx = { error: new TypeError('connection interrupted') };
      jest.spyOn(globalThis, 'fetch').mockResolvedValueOnce(
        new Response(
          new ReadableStream({
            start(controller) {
              controller.error(ctx.error);
            },
          }),
        ),
      );
      mocks.api.getTicketByFreshdeskId.mockResolvedValue(mapping);
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.freshdesk.listConversationsAfter.mockResolvedValue([
        conversation(5, { attachments: [freshdeskImageStub] }),
      ] as never);

      await expect(sut.onFreshdeskPing('42')).rejects.toBe(ctx.error);

      expect(mocks.discord.sendToThread).not.toHaveBeenCalled();
      expect(mocks.api.updateTicket).not.toHaveBeenCalled();
    });

    it.each(['known', 'unknown', 'underreported'])(
      'preserves links for oversized images with %s Content-Length and cancels their download',
      async (length) => {
        const ctx = { cancel: jest.fn<() => void>() };
        jest.spyOn(globalThis, 'fetch').mockResolvedValueOnce(
          new Response(
            new ReadableStream({
              start(controller) {
                if (length !== 'known') {
                  controller.enqueue(new Uint8Array(discordAttachmentLimit));
                  controller.enqueue(new Uint8Array(1));
                }
              },
              cancel: () => ctx.cancel(),
            }),
            {
              headers:
                length === 'unknown'
                  ? {}
                  : { 'Content-Length': length === 'known' ? String(discordAttachmentLimit + 1) : '1' },
            },
          ),
        );
        mocks.api.getTicketByFreshdeskId.mockResolvedValue(mapping);
        mocks.api.getTicketByThread.mockResolvedValue(mapping);
        mocks.freshdesk.listConversationsAfter.mockResolvedValue([
          conversation(5, { body_text: '', attachments: [freshdeskImageStub] }),
        ] as never);

        await sut.onFreshdeskPing('42');

        expect(ctx.cancel).toHaveBeenCalledTimes(1);
        expect(mocks.discord.sendToThread).toHaveBeenCalledWith('thread-1', {
          embeds: [
            expect.objectContaining({
              data: expect.objectContaining({
                description: expect.stringContaining(freshdeskImageStub.attachment_url),
              }),
            }),
          ],
          files: [],
        });
        expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastFreshdeskConversationId: '5' });
      },
    );

    it('posts agent replies and skips private and own conversations', async () => {
      mocks.api.getTicketByFreshdeskId.mockResolvedValue(mapping);
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.freshdesk.listConversationsAfter.mockResolvedValue([
        conversation(5),
        conversation(6, { user_id: 1 }),
        conversation(7, { private: true }),
      ] as never);

      await sut.onFreshdeskPing('42');

      expect(mocks.discord.sendToThread).toHaveBeenCalledTimes(1);
      expect(mocks.discord.sendToThread).toHaveBeenCalledWith('thread-1', expect.objectContaining({ files: [] }));
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastFreshdeskConversationId: '5' });
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastFreshdeskConversationId: '7' });
    });

    it('closes the discord side and swaps the requester when the ticket is resolved', async () => {
      mocks.api.getTicketByFreshdeskId.mockResolvedValue(mapping);
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.freshdesk.getTicketStatus.mockResolvedValue(4);
      mocks.api.getUserSummary.mockResolvedValue(summary);
      mocks.discord.getThreadById.mockResolvedValue({} as never);

      await sut.onFreshdeskPing('42');

      expect(mocks.discord.sendToThread).toHaveBeenCalledWith(
        'thread-1',
        expect.objectContaining({ content: expect.stringContaining('resolved') }),
      );
      expect(mocks.discord.closeThread).toHaveBeenCalledTimes(2);
      expect(mocks.freshdesk.resolveTicket).not.toHaveBeenCalled();
      expect(mocks.freshdesk.setRequester).toHaveBeenCalledWith('42', 'someone@example.test', 'Someone');
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { closed: true });
    });

    it('ignores unmapped tickets', async () => {
      mocks.api.getTicketByFreshdeskId.mockResolvedValue(null);

      await sut.onFreshdeskPing('9999');

      expect(mocks.freshdesk.listConversationsAfter).not.toHaveBeenCalled();
    });
  });

  describe('onTicketClosed', () => {
    it('resolves the freshdesk ticket and swaps the requester to the real email', async () => {
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.api.getUserSummary.mockResolvedValue(summary);

      await sut.onTicketClosed('thread-1');

      expect(mocks.freshdesk.resolveTicket).toHaveBeenCalledWith('42');
      expect(mocks.freshdesk.setRequester).toHaveBeenCalledWith('42', 'someone@example.test', 'Someone');
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { closed: true });
    });

    it('keeps the requester when email updates are already on', async () => {
      mocks.api.getTicketByThread.mockResolvedValue({ ...mapping, emailSubscribed: true });

      await sut.onTicketClosed('thread-1');

      expect(mocks.freshdesk.resolveTicket).toHaveBeenCalledWith('42');
      expect(mocks.freshdesk.setRequester).not.toHaveBeenCalled();
    });

    it('skips a ticket without a linked account', async () => {
      mocks.api.getTicketByThread.mockResolvedValue({ ...mapping, userId: null });

      await sut.onTicketClosed('thread-1');

      expect(mocks.freshdesk.setRequester).not.toHaveBeenCalled();
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { closed: true });
    });
  });

  describe('onEmailUpdatesCommand', () => {
    it('subscribes by swapping the requester to the real email', async () => {
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.api.getUserSummary.mockResolvedValue(summary);
      const interaction = newInteraction();

      await sut.onEmailUpdatesCommand(interaction);

      expect(mocks.freshdesk.setRequester).toHaveBeenCalledWith('42', 'someone@example.test', 'Someone');
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { emailSubscribed: true });
      expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith(
        expect.objectContaining({ content: expect.stringContaining('someone@example.test') }),
      );
    });

    it('unsubscribes by swapping back to the dummy address', async () => {
      mocks.api.getTicketByThread.mockResolvedValue({ ...mapping, emailSubscribed: true });
      const interaction = newInteraction();

      await sut.onEmailUpdatesCommand(interaction);

      expect(mocks.freshdesk.setRequester).toHaveBeenCalledWith('42', 'cust@no.futo.org', 'someone');
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { emailSubscribed: false });
    });

    it('refuses anyone but the ticket owner', async () => {
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      const interaction = newInteraction({ user: { id: 'staff', username: 'staffer' } });

      await sut.onEmailUpdatesCommand(interaction);

      expect(mocks.freshdesk.setRequester).not.toHaveBeenCalled();
      expect((interaction as { reply: jest.Mock }).reply).toHaveBeenCalledWith(
        expect.objectContaining({ content: expect.stringContaining('owner') }),
      );
    });

    it('refuses the staff-notes thread', async () => {
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      const interaction = newInteraction({ channelId: 'staff-1' });

      await sut.onEmailUpdatesCommand(interaction);

      expect(mocks.freshdesk.setRequester).not.toHaveBeenCalled();
      expect((interaction as { reply: jest.Mock }).reply).toHaveBeenCalledWith(
        expect.objectContaining({ content: expect.stringContaining('ticket thread') }),
      );
    });

    it('refuses a ticket without a linked account', async () => {
      mocks.api.getTicketByThread.mockResolvedValue({ ...mapping, userId: null });
      const interaction = newInteraction();

      await sut.onEmailUpdatesCommand(interaction);

      expect(mocks.freshdesk.setRequester).not.toHaveBeenCalled();
      expect((interaction as { reply: jest.Mock }).reply).toHaveBeenCalledWith(
        expect.objectContaining({ content: expect.stringContaining('no linked') }),
      );
    });
  });

  describe('onHandoffCommand', () => {
    it('closes the discord side, swaps the requester and leaves the freshdesk ticket open', async () => {
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.api.getUserSummary.mockResolvedValue(summary);
      mocks.discord.getThreadById.mockResolvedValue({} as never);
      const interaction = staffInteraction();

      await sut.onHandoffCommand(interaction);

      expect(mocks.freshdesk.setRequester).toHaveBeenCalledWith('42', 'someone@example.test', 'Someone');
      expect(mocks.freshdesk.resolveTicket).not.toHaveBeenCalled();
      expect(mocks.freshdesk.createNote).toHaveBeenCalledWith('42', expect.stringContaining('staffer'), {
        private: true,
      });
      expect(mocks.discord.sendToThread).toHaveBeenCalledWith(
        'thread-1',
        expect.objectContaining({ content: expect.stringContaining('<@cust>') }),
      );
      expect(mocks.discord.closeThread).toHaveBeenCalledTimes(2);
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { closed: true });
      expect((interaction as { editReply: jest.Mock }).editReply).toHaveBeenCalledWith(
        expect.objectContaining({ content: expect.stringContaining('Handed off') }),
      );
    });

    it('refuses non-staff', async () => {
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      const interaction = newInteraction({ member: { roles: [] as string[] } });

      await sut.onHandoffCommand(interaction);

      expect(mocks.freshdesk.setRequester).not.toHaveBeenCalled();
      expect((interaction as { reply: jest.Mock }).reply).toHaveBeenCalledWith(
        expect.objectContaining({ content: expect.stringContaining('staff') }),
      );
    });

    it('refuses a ticket without a linked account', async () => {
      mocks.api.getTicketByThread.mockResolvedValue({ ...mapping, userId: null });
      const interaction = staffInteraction();

      await sut.onHandoffCommand(interaction);

      expect(mocks.freshdesk.setRequester).not.toHaveBeenCalled();
      expect(mocks.discord.closeThread).not.toHaveBeenCalled();
      expect((interaction as { reply: jest.Mock }).reply).toHaveBeenCalledWith(
        expect.objectContaining({ content: expect.stringContaining('no linked') }),
      );
    });

    it('refuses an already-closed ticket', async () => {
      mocks.api.getTicketByThread.mockResolvedValue({ ...mapping, closedAt: new Date() });
      const interaction = staffInteraction();

      await sut.onHandoffCommand(interaction);

      expect(mocks.freshdesk.setRequester).not.toHaveBeenCalled();
      expect((interaction as { reply: jest.Mock }).reply).toHaveBeenCalledWith(
        expect.objectContaining({ content: expect.stringContaining('already closed') }),
      );
    });
  });

  describe('poll', () => {
    it('force-mirrors staff image-only messages as outgoing replies', async () => {
      mocks.api.listOpenTickets.mockResolvedValue([mapping]);
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.discord.fetchMessagesAfter.mockImplementation((threadId) =>
        Promise.resolve(threadId === 'thread-1' ? [imageMsg('m1', 'staff')] : []),
      );

      await sut.poll();

      expect(mocks.freshdesk.createReply).toHaveBeenCalledWith('42', '<b>user-staff</b>:<br><i>(attachment)</i>', [
        imageStub,
      ]);
      expect(mocks.freshdesk.createNote).not.toHaveBeenCalled();
      expect(mocks.api.updateTicket).toHaveBeenCalledWith('map-1', { lastMirroredMessageId: 'm1' });
    });

    it('force-mirrors and ingests open tickets', async () => {
      mocks.api.listOpenTickets.mockResolvedValue([mapping]);
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.freshdesk.listUpdatedTicketIds.mockResolvedValue(['42']);
      mocks.discord.fetchMessagesAfter.mockResolvedValue([msg('m1', 'staff')]);
      mocks.freshdesk.listConversationsAfter.mockResolvedValue([conversation(5)] as never);

      await sut.poll();

      expect(mocks.freshdesk.createReply).toHaveBeenCalled();
      expect(mocks.discord.sendToThread).toHaveBeenCalledWith('thread-1', expect.anything());
    });

    it('checks saved cursors even when tickets have no recent update', async () => {
      mocks.api.listOpenTickets.mockResolvedValue([mapping]);
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.freshdesk.listUpdatedTicketIds.mockResolvedValue([]);

      await sut.poll();

      expect(mocks.freshdesk.listConversationsAfter).toHaveBeenCalledWith('42', null);
      expect(mocks.freshdesk.listUpdatedTicketIds).not.toHaveBeenCalled();
    });

    it('does not need the updated ticket listing to recover pending conversations', async () => {
      mocks.api.listOpenTickets.mockResolvedValue([mapping]);
      mocks.api.getTicketByThread.mockResolvedValue(mapping);
      mocks.freshdesk.listUpdatedTicketIds.mockResolvedValue(null);

      await sut.poll();

      expect(mocks.freshdesk.listConversationsAfter).toHaveBeenCalledWith('42', null);
    });
  });
});
