import { jest } from '@jest/globals';
import {
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
  ChannelType,
  Collection,
  DiscordAPIError,
  Guild,
  GuildChannelOverwriteOptions,
  GuildMember,
  Message,
  MessageCreateOptions,
  OverwriteType,
  PermissionFlagsBits,
  PermissionOverwriteOptions,
  PermissionOverwrites,
  PermissionsBitField,
  Role,
  TextChannel,
  ThreadChannel,
} from 'discord.js';
import { ComponentId } from 'src/enum.js';
import { Messages } from 'src/messages.js';
import { DiscordRepository, TicketAttachmentPermissionError } from 'src/repositories/discord.repository.js';

const controlsStub = [
  new ActionRowBuilder<ButtonBuilder>().addComponents(
    new ButtonBuilder()
      .setCustomId(ComponentId.Investigate)
      .setLabel('Investigate again')
      .setStyle(ButtonStyle.Secondary),
  ),
];

const newSeed = (overrides: object = {}): Message =>
  ({
    id: 'seed',
    author: { id: 'own-bot', bot: true },
    content: 'Support ticket for <@1234567890>.',
    components: [{ components: [{ customId: ComponentId.CloseTicket }] }],
    embeds: [{ title: Messages.ticketEmbedTitle, description: 'Backups fail\nError: repository unavailable' }],
    ...overrides,
  }) as never;

const newThread = (overrides: object = {}) => ({
  id: 'ticket-thread',
  guildId: 'guild',
  parentId: 'support-channel',
  name: 'ticket-customer',
  archived: false,
  locked: false,
  ...overrides,
});

const newPermissionContext = () => {
  const roles = new Collection<string, Role>();
  const members = new Collection<string, GuildMember>();
  const overwrites = new Collection<string, PermissionOverwrites>();
  const edit =
    jest.fn<
      (roleId: string, options: PermissionOverwriteOptions, extra: GuildChannelOverwriteOptions) => Promise<TextChannel>
    >();
  const fetchChannel = jest.fn<(force: boolean) => Promise<TextChannel>>();
  const fetchMember = jest.fn<(options: { user: string; force: boolean }) => Promise<GuildMember>>();
  const fetchMe = jest.fn<() => Promise<GuildMember>>();
  const guild = {
    id: 'guild',
    ownerId: 'server-owner',
    roles: {
      get everyone() {
        return roles.get('guild');
      },
      resolve: (value: string | { id: string }) => roles.get(typeof value === 'string' ? value : value.id) ?? null,
    },
    members: {
      resolve: (value: string | { id: string }) => members.get(typeof value === 'string' ? value : value.id) ?? null,
      fetch: fetchMember,
      fetchMe,
    },
  } as unknown as Guild;
  const channel = Object.assign(Object.create(TextChannel.prototype) as TextChannel, {
    id: 'support-channel',
    guild,
    permissionOverwrites: { cache: overwrites, edit },
    fetch: fetchChannel,
  });
  for (const roleId of ['guild', 'customer-role', 'staff-role', 'bot-role']) {
    roles.set(roleId, {
      id: roleId,
      guild,
      permissions: new PermissionsBitField(
        roleId === 'guild'
          ? [PermissionFlagsBits.ViewChannel, PermissionFlagsBits.SendMessagesInThreads]
          : roleId === 'bot-role'
            ? [PermissionFlagsBits.ManageRoles, PermissionFlagsBits.AttachFiles]
            : [],
      ),
    } as Role);
  }
  const member = {
    id: 'ticket-user',
    roles: {
      cache: new Collection([
        ['guild', roles.get('guild')!],
        ['customer-role', roles.get('customer-role')!],
      ]),
    },
  } as unknown as GuildMember;
  const bot = {
    id: 'own-bot',
    roles: {
      cache: new Collection([
        ['guild', roles.get('guild')!],
        ['bot-role', roles.get('bot-role')!],
      ]),
    },
  } as unknown as GuildMember;
  members.set(member.id, member);
  members.set(bot.id, bot);
  for (const roleId of ['guild', 'customer-role', 'staff-role']) {
    overwrites.set(roleId, {
      id: roleId,
      type: OverwriteType.Role,
      allow: new PermissionsBitField(),
      deny: new PermissionsBitField([
        PermissionFlagsBits.AttachFiles,
        ...(roleId === 'guild' ? [PermissionFlagsBits.SendMessages] : [PermissionFlagsBits.ManageThreads]),
      ]),
    } as PermissionOverwrites);
  }
  edit.mockImplementation((roleId, options, extra) => {
    const resolved = PermissionOverwrites.resolveOverwriteOptions(options, overwrites.get(roleId) ?? {});
    overwrites.set(roleId, {
      id: roleId,
      type: extra.type,
      allow: new PermissionsBitField(resolved.allow),
      deny: new PermissionsBitField(resolved.deny),
    } as PermissionOverwrites);
    return Promise.resolve(channel);
  });
  fetchChannel.mockResolvedValue(channel);
  fetchMember.mockImplementation((options) => Promise.resolve(members.get(options.user)!));
  fetchMe.mockResolvedValue(bot);
  return { channel, roles, members, overwrites, edit, fetchChannel, fetchMember, fetchMe, member, bot };
};

describe(DiscordRepository.name, () => {
  let sut: DiscordRepository;
  let mocks: {
    fetchMessages: jest.Mock<(options: unknown) => Promise<Map<string, Message>>>;
    send: jest.Mock<(options: MessageCreateOptions) => Promise<Message>>;
    create: jest.Mock<() => Promise<ThreadChannel>>;
    guildFetch: jest.Mock<() => Promise<Guild>>;
    channelFetch: jest.Mock<() => Promise<TextChannel>>;
    logger: { warn: jest.Mock<(error: unknown, message: string) => void> };
  };

  beforeEach(() => {
    mocks = {
      fetchMessages: jest.fn<(options: unknown) => Promise<Map<string, Message>>>().mockResolvedValue(new Map()),
      send: jest
        .fn<(options: MessageCreateOptions) => Promise<Message>>()
        .mockResolvedValue({ id: 'staff-seed' } as Message),
      create: jest.fn<() => Promise<ThreadChannel>>(),
      guildFetch: jest.fn<() => Promise<Guild>>(),
      channelFetch: jest.fn<() => Promise<TextChannel>>(),
      logger: { warn: jest.fn<(error: unknown, message: string) => void>() },
    };
    const ctx = Object.assign(Object.create(TextChannel.prototype) as TextChannel, {
      threads: { create: mocks.create },
    });
    mocks.create.mockResolvedValue({ id: 'staff-thread', send: mocks.send } as never);
    mocks.channelFetch.mockResolvedValue(ctx);
    mocks.guildFetch.mockResolvedValue({ channels: { fetch: mocks.channelFetch } } as never);
    sut = new DiscordRepository(mocks.logger as never);
    Object.assign(sut, { client: { user: { id: 'own-bot' }, guilds: { fetch: mocks.guildFetch } } });
    jest.spyOn(sut, 'getThreadById').mockResolvedValue({ messages: { fetch: mocks.fetchMessages } } as never);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  describe('ensureTicketAttachmentPermissions', () => {
    it('grants only role attachment permissions while retaining the read-only support parent and moderation denies', async () => {
      const ctx = newPermissionContext();
      mocks.channelFetch.mockResolvedValue(ctx.channel);

      await sut.ensureTicketAttachmentPermissions();

      expect(ctx.edit.mock.calls.map(([roleId]) => roleId)).toEqual(['guild', 'customer-role', 'staff-role']);
      for (const roleId of ['guild', 'customer-role', 'staff-role']) {
        expect(ctx.edit).toHaveBeenCalledWith(
          roleId,
          { AttachFiles: true },
          {
            type: OverwriteType.Role,
            reason: 'Enable attachments in support ticket threads',
          },
        );
      }
      expect(ctx.channel.permissionsFor(ctx.member)?.has(PermissionFlagsBits.AttachFiles)).toBe(true);
      expect(ctx.channel.permissionsFor(ctx.member)?.has(PermissionFlagsBits.SendMessagesInThreads)).toBe(true);
      expect(ctx.channel.permissionsFor(ctx.member)?.has(PermissionFlagsBits.SendMessages)).toBe(false);
      expect(ctx.channel.permissionsFor(ctx.member)?.has(PermissionFlagsBits.ManageThreads)).toBe(false);
      expect(ctx.overwrites.get('guild')?.deny.has(PermissionFlagsBits.SendMessages)).toBe(true);
      expect(ctx.overwrites.get('customer-role')?.deny.has(PermissionFlagsBits.ManageThreads)).toBe(true);
      expect(ctx.fetchChannel).toHaveBeenCalledWith(true);
    });

    it('does not require Manage Roles when configured roles already allow attachments', async () => {
      const ctx = newPermissionContext();
      for (const overwrite of ctx.overwrites.values()) {
        overwrite.allow.add(PermissionFlagsBits.AttachFiles);
        overwrite.deny.remove(PermissionFlagsBits.AttachFiles);
      }
      ctx.roles.get('bot-role')!.permissions.remove(PermissionFlagsBits.ManageRoles);
      mocks.channelFetch.mockResolvedValue(ctx.channel);

      await sut.ensureTicketAttachmentPermissions();

      expect(ctx.edit).not.toHaveBeenCalled();
      expect(ctx.fetchMe).not.toHaveBeenCalled();
      expect(mocks.logger.warn).not.toHaveBeenCalled();
    });

    it('updates only the configured role that still denies attachments', async () => {
      const ctx = newPermissionContext();
      for (const [roleId, overwrite] of ctx.overwrites) {
        if (roleId !== 'customer-role') {
          overwrite.allow.add(PermissionFlagsBits.AttachFiles);
          overwrite.deny.remove(PermissionFlagsBits.AttachFiles);
        }
      }
      mocks.channelFetch.mockResolvedValue(ctx.channel);

      await sut.ensureTicketAttachmentPermissions();

      expect(ctx.edit).toHaveBeenCalledTimes(1);
      expect(ctx.edit).toHaveBeenCalledWith('customer-role', { AttachFiles: true }, expect.anything());
    });

    it('preserves existing restrictions on viewing the support parent', async () => {
      const ctx = newPermissionContext();
      ctx.overwrites.get('guild')!.deny.add(PermissionFlagsBits.ViewChannel);
      mocks.channelFetch.mockResolvedValue(ctx.channel);

      await sut.ensureTicketAttachmentPermissions();

      expect(ctx.overwrites.get('guild')?.deny.has(PermissionFlagsBits.ViewChannel)).toBe(true);
      expect(ctx.channel.permissionsFor(ctx.member)?.has(PermissionFlagsBits.ViewChannel)).toBe(false);
      expect(ctx.channel.permissionsFor(ctx.member)?.has(PermissionFlagsBits.SendMessages)).toBe(false);
    });

    it('reports actionable setup instructions when the bot cannot repair missing attachment permission', async () => {
      const ctx = newPermissionContext();
      ctx.roles.get('bot-role')!.permissions.remove(PermissionFlagsBits.ManageRoles);
      mocks.channelFetch.mockResolvedValue(ctx.channel);

      await expect(sut.ensureTicketAttachmentPermissions()).rejects.toThrow(TicketAttachmentPermissionError);

      expect(ctx.edit).not.toHaveBeenCalled();
      expect(mocks.logger.warn).toHaveBeenCalledWith(
        expect.objectContaining({
          message: expect.stringContaining('Attach Files in support channel support-channel'),
        }),
        'could not enable support ticket attachments',
      );
      expect(mocks.logger.warn).toHaveBeenCalledWith(
        expect.objectContaining({ message: expect.stringContaining('Manage Roles') }),
        'could not enable support ticket attachments',
      );
    });

    it('wraps API permission failures without replacing other channel overwrites', async () => {
      const ctx = { ...newPermissionContext(), error: new TypeError('Missing Permissions') };
      ctx.edit.mockRejectedValueOnce(ctx.error);
      mocks.channelFetch.mockResolvedValue(ctx.channel);

      await expect(sut.ensureTicketAttachmentPermissions()).rejects.toThrow(TicketAttachmentPermissionError);

      expect(ctx.edit).toHaveBeenCalledTimes(1);
      expect(ctx.fetchChannel).not.toHaveBeenCalled();
      expect(mocks.logger.warn).toHaveBeenCalledWith(
        expect.objectContaining({ cause: ctx.error }),
        'could not enable support ticket attachments',
      );
      expect(ctx.overwrites.get('guild')?.deny.has(PermissionFlagsBits.SendMessages)).toBe(true);
    });

    it('retains member-specific attachment denies when repairing the shared role configuration', async () => {
      const ctx = newPermissionContext();
      ctx.overwrites.set(ctx.member.id, {
        id: ctx.member.id,
        type: OverwriteType.Member,
        allow: new PermissionsBitField(),
        deny: new PermissionsBitField(PermissionFlagsBits.AttachFiles),
      } as PermissionOverwrites);
      mocks.channelFetch.mockResolvedValue(ctx.channel);

      await sut.ensureTicketAttachmentPermissions();

      expect(ctx.channel.permissionsFor(ctx.member)?.has(PermissionFlagsBits.AttachFiles)).toBe(false);
      expect(ctx.overwrites.get(ctx.member.id)?.deny.has(PermissionFlagsBits.AttachFiles)).toBe(true);
      expect(ctx.edit.mock.calls.every((call) => call[2].type === OverwriteType.Role)).toBe(true);
    });
  });

  describe('canSendTicketAttachments', () => {
    let ctx: ReturnType<typeof newPermissionContext>;

    beforeEach(() => {
      ctx = newPermissionContext();
      for (const overwrite of ctx.overwrites.values()) {
        overwrite.allow.add(PermissionFlagsBits.AttachFiles);
        overwrite.deny.remove(PermissionFlagsBits.AttachFiles);
      }
      mocks.channelFetch.mockResolvedValue(ctx.channel);
    });

    it('checks fresh effective thread permissions without requiring Send Messages in the parent', async () => {
      expect(await sut.canSendTicketAttachments('ticket-user')).toBe(true);

      expect(ctx.fetchChannel).toHaveBeenCalledWith(true);
      expect(ctx.fetchMember).toHaveBeenCalledWith({ user: 'ticket-user', force: true });
      expect(ctx.channel.permissionsFor(ctx.member)?.has(PermissionFlagsBits.SendMessages)).toBe(false);
      expect(ctx.edit).not.toHaveBeenCalled();
    });

    it.each([
      ['Attach Files', PermissionFlagsBits.AttachFiles],
      ['View Channel', PermissionFlagsBits.ViewChannel],
      ['Send Messages in Threads', PermissionFlagsBits.SendMessagesInThreads],
    ])('reports missing %s permission without bypassing a member deny', async (_name, permission) => {
      ctx.overwrites.set(ctx.member.id, {
        id: ctx.member.id,
        type: OverwriteType.Member,
        allow: new PermissionsBitField(),
        deny: new PermissionsBitField(permission),
      } as PermissionOverwrites);

      expect(await sut.canSendTicketAttachments('ticket-user')).toBe(false);

      expect(ctx.edit).not.toHaveBeenCalled();
    });

    it('reports unavailable permissions for an unresolved member', async () => {
      ctx.fetchMember.mockResolvedValue({ id: 'unknown-user' } as GuildMember);

      expect(await sut.canSendTicketAttachments('ticket-user')).toBe(false);

      expect(ctx.edit).not.toHaveBeenCalled();
    });
  });

  describe('getTicketOpening', () => {
    it.each(['<@1234567890>', '<@!1234567890>'])(
      'extracts the owner from %s and the original support description',
      async (mention) => {
        mocks.fetchMessages.mockResolvedValue(
          new Map([['seed', newSeed({ content: `Support ticket for ${mention}.` })]]),
        );

        const ctx = await sut.getTicketOpening('ticket-thread');

        expect(ctx).toEqual({
          discordUserId: '1234567890',
          description: 'Backups fail\nError: repository unavailable',
        });
        expect(sut.getThreadById).toHaveBeenCalledWith('ticket-thread');
        expect(mocks.fetchMessages).toHaveBeenCalledWith({ after: '0', limit: 100 });
      },
    );

    it.each([
      { name: 'another bot', overrides: { author: { id: 'another-bot', bot: true } } },
      { name: 'a user', overrides: { author: { id: '1234567890', bot: false } } },
      { name: 'a message without controls', overrides: { components: [] } },
      {
        name: 'a message with unrelated controls',
        overrides: { components: [{ components: [{ customId: ComponentId.OpenTicket }] }] },
      },
      {
        name: 'an unrelated embed',
        overrides: { embeds: [{ title: 'Another message', description: 'Not the ticket description' }] },
      },
      { name: 'a message without a support embed', overrides: { embeds: [] } },
      { name: 'a support embed without a description', overrides: { embeds: [{ title: Messages.ticketEmbedTitle }] } },
      { name: 'a message without an owner mention', overrides: { content: 'Support ticket' } },
    ])('refuses $name as the ticket seed', async ({ overrides }) => {
      mocks.fetchMessages.mockResolvedValue(new Map([['seed', newSeed(overrides)]]));

      expect(await sut.getTicketOpening('ticket-thread')).toBeNull();
    });

    it('ignores untrusted messages before the original bot seed', async () => {
      mocks.fetchMessages.mockResolvedValue(
        new Map([
          ['user', newSeed({ author: { id: '1234567890', bot: false }, content: '<@9999999999>' })],
          ['bot', newSeed({ author: { id: 'another-bot', bot: true }, content: '<@8888888888>' })],
          ['seed', newSeed()],
        ]),
      );

      expect(await sut.getTicketOpening('ticket-thread')).toEqual({
        discordUserId: '1234567890',
        description: 'Backups fail\nError: repository unavailable',
      });
    });

    it('requires the support embed and close control on the same seed message', async () => {
      mocks.fetchMessages.mockResolvedValue(
        new Map([
          ['controls', newSeed({ embeds: [] })],
          ['embed', newSeed({ components: [] })],
        ]),
      );

      expect(await sut.getTicketOpening('ticket-thread')).toBeNull();
    });

    it('selects the support seed when an unrelated bot close control appears earlier', async () => {
      mocks.fetchMessages.mockResolvedValue(
        new Map([
          ['unrelated', newSeed({ embeds: [{ title: 'Another message', description: 'Unrelated' }] })],
          ['seed', newSeed()],
        ]),
      );

      expect(await sut.getTicketOpening('ticket-thread')).toEqual({
        discordUserId: '1234567890',
        description: 'Backups fail\nError: repository unavailable',
      });
    });

    it('returns null when there is no original ticket message', async () => {
      expect(await sut.getTicketOpening('ticket-thread')).toBeNull();
    });
  });

  describe('getTicketContext', () => {
    it('recovers the original owner and includes fresh customer text and attachments', async () => {
      jest
        .mocked(sut.getThreadById)
        .mockResolvedValue({ ...newThread(), messages: { fetch: mocks.fetchMessages } } as never);
      mocks.fetchMessages.mockResolvedValueOnce(new Map([['seed', newSeed()]]));
      mocks.fetchMessages.mockResolvedValueOnce(
        new Map([
          [
            'followup',
            {
              id: 'followup',
              author: { id: '1234567890', username: 'Customer', bot: false },
              content: 'This is the new restore error',
              createdAt: new Date('2026-10-22T12:00:00Z'),
              createdTimestamp: 100,
              embeds: [],
              attachments: new Map([
                ['image', { id: 'image', name: 'error.png', url: 'https://cdn.discordapp.com/error.png', size: 42 }],
              ]),
            } as never,
          ],
        ]),
      );

      const result = await sut.getTicketContext('ticket-thread');

      expect(sut.getThreadById).toHaveBeenCalledWith('ticket-thread', true);
      expect(result).toEqual({
        ticketThreadId: 'ticket-thread',
        discordUserId: '1234567890',
        closed: false,
        messages: [
          {
            id: 'followup',
            authorId: '1234567890',
            username: 'Customer',
            content: 'This is the new restore error',
            createdAt: '2026-10-22T12:00:00.000Z',
            attachments: [{ id: 'image', name: 'error.png', url: 'https://cdn.discordapp.com/error.png', size: 42 }],
          },
        ],
      });
    });

    it.each([
      { guildId: 'another-guild' },
      { parentId: 'another-parent' },
      { name: 'staff-customer' },
      { name: 'unrelated-thread' },
    ])('rejects out-of-scope and staff threads before reading any messages', async (overrides) => {
      jest.mocked(sut.getThreadById).mockResolvedValue(newThread(overrides) as never);

      await expect(sut.getTicketContext('ticket-thread')).resolves.toBeNull();

      expect(mocks.fetchMessages).not.toHaveBeenCalled();
    });

    it('rejects a thread without an original trusted ticket seed', async () => {
      jest
        .mocked(sut.getThreadById)
        .mockResolvedValue({ ...newThread(), messages: { fetch: mocks.fetchMessages } } as never);

      await expect(sut.getTicketContext('ticket-thread')).resolves.toBeNull();

      expect(mocks.fetchMessages).toHaveBeenCalledTimes(1);
    });

    it.each([
      { archived: true, locked: false, closed: false },
      { archived: false, locked: true, closed: true },
      { archived: true, locked: true, closed: true },
    ])('reports closure for archived=$archived and locked=$locked', async ({ archived, locked, closed }) => {
      jest
        .mocked(sut.getThreadById)
        .mockResolvedValue({ ...newThread({ archived, locked }), messages: { fetch: mocks.fetchMessages } } as never);
      jest
        .spyOn(sut, 'getTicketOpening')
        .mockResolvedValue({ discordUserId: 'customer-1', description: 'Original issue' });

      await expect(sut.getTicketContext('ticket-thread')).resolves.toEqual(
        expect.objectContaining({ closed, messages: [] }),
      );
    });

    it('continues past bot noise to find the latest human follow-ups', async () => {
      jest
        .mocked(sut.getThreadById)
        .mockResolvedValue({ ...newThread(), messages: { fetch: mocks.fetchMessages } } as never);
      jest
        .spyOn(sut, 'getTicketOpening')
        .mockResolvedValue({ discordUserId: 'customer-1', description: 'Original issue' });
      mocks.fetchMessages.mockResolvedValueOnce(
        new Map(
          Array.from({ length: 100 }, (_, index) => [
            String(index + 1),
            {
              id: String(index + 1),
              author: { id: 'own-bot', bot: true },
              content: 'Bot notice',
              embeds: [],
              attachments: new Map(),
              createdAt: new Date(index * 1000),
              createdTimestamp: index * 1000,
            } as never,
          ]),
        ),
      );
      mocks.fetchMessages.mockResolvedValueOnce(
        new Map([
          [
            'older',
            {
              id: 'older',
              author: { id: 'customer-1', username: 'Customer', bot: false },
              content: 'Human follow-up',
              embeds: [],
              attachments: new Map(),
              createdAt: new Date(0),
              createdTimestamp: 0,
            } as never,
          ],
        ]),
      );

      const result = await sut.getTicketContext('ticket-thread');

      expect(result?.messages.map(({ content }) => content)).toEqual(['Human follow-up']);
      expect(mocks.fetchMessages).toHaveBeenLastCalledWith({ limit: 100, before: '1' });
    });

    it.each([
      new TypeError('Channel is not a thread'),
      new DiscordAPIError({ message: 'Missing Access', code: 50_001 }, 50_001, 403, 'GET', '/channels', {}),
      new DiscordAPIError({ message: 'Unknown Channel', code: 10_003 }, 10_003, 404, 'GET', '/channels', {}),
    ])('hides missing and inaccessible channels', async (error) => {
      jest.mocked(sut.getThreadById).mockRejectedValueOnce(error);

      await expect(sut.getTicketContext('ticket-thread')).resolves.toBeNull();
    });

    it('does not expose tickets while the Discord client is unavailable', async () => {
      Object.assign(sut, { client: null });

      await expect(sut.getTicketContext('ticket-thread')).resolves.toBeNull();

      expect(sut.getThreadById).not.toHaveBeenCalled();
    });

    it('propagates transient Discord failures instead of treating them as an accessible empty ticket', async () => {
      const error = new Error('Discord unavailable');
      jest.mocked(sut.getThreadById).mockRejectedValueOnce(error);

      await expect(sut.getTicketContext('ticket-thread')).rejects.toBe(error);
    });
  });

  describe('listThreadMessages', () => {
    it.each([undefined, 25])('returns recent messages chronologically with limit %s', async (limit) => {
      const ctx = {
        messages: [
          { id: 'latest', createdTimestamp: 300 },
          { id: 'oldest', createdTimestamp: 100 },
          { id: 'middle', createdTimestamp: 200 },
        ] as Message[],
        result: [] as Message[],
      };
      mocks.fetchMessages.mockResolvedValue(new Map(ctx.messages.map((message) => [message.id, message])));

      ctx.result = await sut.listThreadMessages('ticket-thread', limit);

      expect(ctx.result.map((message) => message.id)).toEqual(['oldest', 'middle', 'latest']);
      expect(mocks.fetchMessages).toHaveBeenCalledWith({ limit: limit ?? 50 });
    });
  });

  describe('createStaffThread', () => {
    it.each(['Staff context', 'x'.repeat(2000)])('preserves short context and its staff controls', async (content) => {
      await sut.createStaffThread('staff-customer', content, controlsStub);

      expect(mocks.create).toHaveBeenCalledWith({
        name: 'staff-customer',
        type: ChannelType.PrivateThread,
        invitable: false,
        autoArchiveDuration: 10_080,
      });
      expect(mocks.send).toHaveBeenCalledWith({
        content,
        components: controlsStub,
        allowedMentions: { roles: ['staff-role'], users: [], parse: [] },
      });
    });

    it('keeps the complete original version list in a file on the first staff message', async () => {
      const ctx = {
        content: [
          '<@&staff-role> Ticket for <@1234567890> @everyone',
          Messages.versionsHeader,
          ...Array.from(
            { length: 100 },
            (_, index) => `• restic-proxy (client): v1.0.${index} (logs; last seen 2026-10-22T10:00:00Z)`,
          ),
        ].join('\n'),
      };

      await sut.createStaffThread('staff-customer', ctx.content, controlsStub);

      expect(ctx.content.length).toBeGreaterThan(2000);
      expect(mocks.send).toHaveBeenCalledTimes(1);
      expect(mocks.send.mock.calls[0][0].content?.length).toBeLessThanOrEqual(2000);
      expect(mocks.send.mock.calls[0][0].content).toContain('Full staff context is attached.');
      expect(mocks.send.mock.calls[0][0].components).toBe(controlsStub);
      expect(mocks.send.mock.calls[0][0].files).toEqual([
        expect.objectContaining({ name: 'staff-context.txt', attachment: Buffer.from(ctx.content) }),
      ]);
      expect(mocks.send.mock.calls[0][0].allowedMentions).toEqual({ roles: ['staff-role'], users: [], parse: [] });
    });

    it('preserves long staff context and controls as text when attachments are denied', async () => {
      const content = `${'x'.repeat(1999)}😺\n${Messages.versionsHeader}\n${'• client: 1.2.1 (logs)\n'.repeat(220)}`;
      mocks.send.mockRejectedValueOnce(
        new DiscordAPIError({ message: 'Missing Permissions', code: 50_013 }, 50_013, 403, 'POST', '/messages', {}),
      );

      const result = await sut.createStaffThread('staff-customer', content, controlsStub);

      const delivered = mocks.send.mock.calls.slice(1).map(([message]) => message);
      expect(result).toEqual({ thread: expect.objectContaining({ id: 'staff-thread' }), seed: { id: 'staff-seed' } });
      expect(mocks.create).toHaveBeenCalledTimes(1);
      expect(delivered.length).toBeGreaterThan(1);
      expect(delivered.map((message) => message.content).join('')).toBe(content);
      expect(delivered.every((message) => message.content!.length <= 2000 && !message.files)).toBe(true);
      expect(delivered[0].components).toBe(controlsStub);
      expect(delivered[0].content).not.toMatch(/[\uD800-\uDBFF]$/u);
      expect(delivered.slice(1).every((message) => !message.components)).toBe(true);
      expect(delivered.slice(1).every((message) => JSON.stringify(message.allowedMentions) === '{"parse":[]}')).toBe(
        true,
      );
    });

    it('propagates unrelated attachment failures without duplicating context', async () => {
      const error = new Error('Connection interrupted');
      mocks.send.mockRejectedValueOnce(error);

      await expect(sut.createStaffThread('staff-customer', 'x'.repeat(3000), controlsStub)).rejects.toBe(error);

      expect(mocks.send).toHaveBeenCalledTimes(1);
    });
  });
});
