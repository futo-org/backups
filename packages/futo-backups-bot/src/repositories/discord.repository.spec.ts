import { jest } from '@jest/globals';
import {
  Collection,
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
import { DiscordRepository, TicketAttachmentPermissionError } from 'src/repositories/discord.repository.js';

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
});
