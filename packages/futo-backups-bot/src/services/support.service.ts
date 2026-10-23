import { LoggerRepository } from '@common/server/otel';
import { BadRequestException, Injectable, NotFoundException, OnApplicationBootstrap } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import {
  ActionRowBuilder,
  ButtonBuilder,
  ButtonInteraction,
  ButtonStyle,
  ChatInputCommandInteraction,
  EmbedBuilder,
  Interaction,
  Message,
  MessageFlags,
  ModalBuilder,
  ModalSubmitInteraction,
  TextInputBuilder,
  TextInputStyle,
  ThreadChannel,
  User,
} from 'discord.js';
import { ComponentId } from 'src/enum.js';
import { env } from 'src/env.js';
import { Messages } from 'src/messages.js';
import { ColumboRepository } from 'src/repositories/columbo.repository.js';
import { DiscordRepository } from 'src/repositories/discord.repository.js';
import { DiscordLink, UserSummary, YuccaApiRepository } from 'src/repositories/yuccaApi.repository.js';
import { FreshdeskSyncService } from 'src/services/freshdeskSync.service.js';
import { InviteService } from 'src/services/invite.service.js';
import { isStaff } from 'src/utils/staff.js';
import { TicketContext } from 'src/utils/ticketContext.js';
import { formatVersions } from 'src/utils/versions.js';

const LINK_POLL_INTERVAL_MS = 5000;
const LINK_LOOKUP_TIMEOUT_MS = 2000;
const INVESTIGATION_CONTEXT_MAX_LENGTH = 16_000;
const INVESTIGATION_PROMPT_MAX_LENGTH = 2000;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const withTimeout = <T>(promise: Promise<T>, ms: number): Promise<T> =>
  new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timed out after ${ms}ms`)), ms);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(timer);
        reject(error instanceof Error ? error : new Error(String(error)));
      },
    );
  });

@Injectable()
export class SupportService implements OnApplicationBootstrap {
  private readonly creating = new Set<string>();

  constructor(
    private readonly logger: LoggerRepository,
    private readonly discord: DiscordRepository,
    private readonly api: YuccaApiRepository,
    private readonly invite: InviteService,
    private readonly freshdeskSync: FreshdeskSyncService,
    private readonly columbo: ColumboRepository,
  ) {}

  async onApplicationBootstrap() {
    if (!this.discord.enabled) {
      return;
    }
    await this.discord.start(
      (interaction) => this.handleInteraction(interaction),
      (message) => this.handleMessage(message),
    );
    try {
      await this.discord.registerCommands();
    } catch (error) {
      this.logger.error(error, 'failed to register slash commands — is the applications.commands scope granted?');
    }
    await this.discord
      .ensureTicketAttachmentPermissions()
      .catch((error: unknown) => this.logger.warn(error, 'ticket attachment permissions need staff attention'));
    await this.discord.ensurePinnedMessage(
      env.DISCORD_SUPPORT_CHANNEL_ID,
      {
        content: Messages.supportSticky,
        components: [this.buttonRow(ComponentId.OpenTicket, Messages.supportStickyButton)],
      },
      ComponentId.OpenTicket,
    );
  }

  async handleMessage(message: Message): Promise<void> {
    const channel = message.channel;
    if (
      this.columbo.enabled &&
      !message.author.bot &&
      message.guildId === env.DISCORD_GUILD_ID &&
      channel.isThread() &&
      channel.parentId === env.DISCORD_SUPPORT_CHANNEL_ID &&
      channel.name.startsWith('ticket-') &&
      !channel.archived &&
      !channel.locked
    ) {
      void this.columbo
        .notifyTicketActivity(channel.id, { authorId: message.author.id, messageId: message.id })
        .catch((error: unknown) => this.logger.warn(error, 'could not notify columbo of ticket activity'));
    }
    await this.freshdeskSync.handleMessage(message);
  }

  async getTicketContext(threadId: string): Promise<TicketContext> {
    const context = await this.discord.getTicketContext(threadId);
    if (!context) {
      throw new NotFoundException('Ticket not found');
    }
    const mapping = env.INTERNAL_SECRET ? await this.api.getTicketByThread(threadId) : null;
    if (mapping && (mapping.threadId !== threadId || mapping.discordUserId !== context.discordUserId)) {
      throw new NotFoundException('Ticket not found');
    }
    return { ...context, closed: context.closed || Boolean(mapping?.closedAt) };
  }

  async handleInteraction(interaction: Interaction): Promise<void> {
    // Staging and prod share one Discord application, so every pod is a member
    // of every bound guild and sees the others' interactions. Custom ids and
    // command names are identical across guilds, so without this both pods act
    // on the same click.
    if (env.DISCORD_GUILD_ID && interaction.guildId !== env.DISCORD_GUILD_ID) {
      return;
    }
    try {
      if (interaction.isButton() && interaction.customId.startsWith(`${ComponentId.ClaimInvite}:`)) {
        return await this.invite.onClaimInvite(interaction);
      }
      if (interaction.isButton()) {
        switch (interaction.customId) {
          case ComponentId.OpenTicket:
          case ComponentId.CreateTicket: {
            return await this.onOpenRequested(interaction);
          }
          case ComponentId.CloseTicket: {
            return await this.onCloseRequested(interaction);
          }
          case ComponentId.ClaimRole: {
            return await this.onClaimRequested(interaction);
          }
          case ComponentId.Investigate: {
            return await this.onInvestigationRequested(interaction);
          }
        }
      }
      if (interaction.isModalSubmit() && interaction.customId === ComponentId.TicketModal) {
        return await this.onTicketSubmitted(interaction);
      }
      if (interaction.isModalSubmit() && interaction.customId === ComponentId.InvestigationModal) {
        return await this.onInvestigationRequested(interaction);
      }
      if (interaction.isChatInputCommand() && interaction.commandName === 'investigate') {
        return await this.onInvestigationRequested(interaction);
      }
      if (interaction.isChatInputCommand() && interaction.commandName === 'ticket') {
        return await this.onStaffTicket(interaction);
      }
      if (interaction.isChatInputCommand() && interaction.commandName === 'staff-notes') {
        return await this.onStaffNotesRequested(interaction);
      }
      if (interaction.isChatInputCommand() && interaction.commandName === 'claim-backups-role') {
        return await this.onClaimRequested(interaction);
      }
      if (interaction.isChatInputCommand() && interaction.commandName === 'email-updates') {
        return await this.freshdeskSync.onEmailUpdatesCommand(interaction);
      }
      if (interaction.isChatInputCommand() && interaction.commandName === 'handoff') {
        return await this.freshdeskSync.onHandoffCommand(interaction);
      }
      if (interaction.isChatInputCommand() && interaction.commandName === 'beta-invite') {
        return await this.invite.onInviteCommand(interaction);
      }
    } catch (error) {
      this.logger.error(error, 'failed to handle interaction');
      if (!interaction.isButton() && !interaction.isModalSubmit() && !interaction.isChatInputCommand()) {
        return;
      }
      const content = Messages.somethingWentWrong;
      if (interaction.deferred) {
        await interaction.editReply({ content }).catch(() => {});
      } else if (!interaction.replied) {
        await interaction.reply({ content, flags: MessageFlags.Ephemeral }).catch(() => {});
      }
    }
  }

  private async onOpenRequested(interaction: ButtonInteraction) {
    let link: DiscordLink | null;
    try {
      link = await withTimeout(this.api.getLink(interaction.user.id), LINK_LOOKUP_TIMEOUT_MS);
    } catch (error) {
      this.logger.error(error, 'link lookup failed');
      await interaction.reply({
        content: Messages.supportUnavailable,
        flags: MessageFlags.Ephemeral,
      });
      return;
    }
    if (!link) {
      await interaction.deferReply({ flags: MessageFlags.Ephemeral });
      return this.startLinkFlow(interaction);
    }
    this.syncUsername(link, interaction.user);

    await interaction.showModal(
      new ModalBuilder()
        .setCustomId(ComponentId.TicketModal)
        .setTitle(Messages.ticketModalTitle)
        .addComponents(
          new ActionRowBuilder<TextInputBuilder>().addComponents(
            new TextInputBuilder()
              .setCustomId(ComponentId.TicketDescription)
              .setLabel(Messages.ticketModalLabel)
              .setStyle(TextInputStyle.Paragraph)
              .setRequired(true)
              .setMinLength(10)
              .setMaxLength(1000),
          ),
        ),
    );
  }

  private async onClaimRequested(interaction: ButtonInteraction | ChatInputCommandInteraction) {
    if (!env.DISCORD_CUSTOMER_ROLE_ID) {
      await interaction.reply({ content: Messages.claimNotAvailable, flags: MessageFlags.Ephemeral });
      return;
    }

    let link: DiscordLink | null;
    try {
      link = await withTimeout(this.api.getLink(interaction.user.id), LINK_LOOKUP_TIMEOUT_MS);
    } catch (error) {
      this.logger.error(error, 'link lookup failed');
      await interaction.reply({
        content: Messages.claimUnavailable,
        flags: MessageFlags.Ephemeral,
      });
      return;
    }

    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    if (!link) {
      return this.startLinkFlow(interaction, async () => {
        await this.discord.addRoleToMember(interaction.user.id, env.DISCORD_CUSTOMER_ROLE_ID);
        return { content: Messages.linkedAndClaimed(Messages.chatMention(env.DISCORD_CHAT_CHANNEL_ID)) };
      });
    }

    await this.discord.addRoleToMember(interaction.user.id, env.DISCORD_CUSTOMER_ROLE_ID);
    await interaction.editReply({ content: Messages.roleClaimed(Messages.chatMention(env.DISCORD_CHAT_CHANNEL_ID)) });
  }

  @Cron(CronExpression.EVERY_DAY_AT_NOON)
  async postClaimPrompt() {
    if (!this.discord.enabled || !env.DISCORD_GENERAL_CHANNEL_ID || !env.DISCORD_CUSTOMER_ROLE_ID) {
      return;
    }

    const messages = await this.discord.listRecentMessages(env.DISCORD_GENERAL_CHANNEL_ID, 50);
    const isPrompt = (message: Message) =>
      message.author.bot &&
      message.components.some(
        (row) =>
          'components' in row &&
          row.components.some((component) => 'customId' in component && component.customId === ComponentId.ClaimRole),
      );
    const lastPrompt = messages
      .filter((message) => isPrompt(message))
      .toSorted((a, b) => b.createdTimestamp - a.createdTimestamp)[0];
    const activity = messages.filter(
      (message) => !message.author.bot && (!lastPrompt || message.createdTimestamp > lastPrompt.createdTimestamp),
    );
    if (activity.length < env.CLAIM_PROMPT_MIN_MESSAGES) {
      return;
    }

    if (lastPrompt) {
      await lastPrompt
        .delete()
        .catch((error: unknown) => this.logger.warn(error, 'could not delete the previous claim prompt'));
    }
    await this.discord.sendMessage(env.DISCORD_GENERAL_CHANNEL_ID, {
      content: Messages.claimPrompt(env.DISCORD_CHAT_CHANNEL_ID),
      components: [this.buttonRow(ComponentId.ClaimRole, Messages.claimPromptButton)],
    });
  }

  private chatMention(): string {
    return env.DISCORD_CHAT_CHANNEL_ID ? ` Say hi in <#${env.DISCORD_CHAT_CHANNEL_ID}>.` : '';
  }

  private async startLinkFlow(
    interaction: ButtonInteraction | ChatInputCommandInteraction,
    onLinked?: () => Promise<{ content: string; components?: ActionRowBuilder<ButtonBuilder>[] }>,
  ) {
    const { code, expiresAt } = await this.api.createLinkRequest(interaction.user.id, interaction.user.username);
    const url = `${env.WEB_URL}/link/discord?code=${code}`;

    await interaction.editReply({
      content: Messages.linkIntro,
      components: [
        new ActionRowBuilder<ButtonBuilder>().addComponents(
          new ButtonBuilder().setStyle(ButtonStyle.Link).setLabel(Messages.linkButton).setURL(url),
        ),
      ],
    });

    while (Date.now() < expiresAt.getTime()) {
      const link = await this.api.getLink(interaction.user.id).catch(() => null);
      if (link) {
        const success = onLinked
          ? await onLinked()
          : {
              content: Messages.linkedOpenTicket,
              components: [this.buttonRow(ComponentId.CreateTicket, Messages.openTicketButton)],
            };
        await interaction.editReply({ components: [], ...success });
        return;
      }
      await sleep(LINK_POLL_INTERVAL_MS);
    }

    await interaction.editReply({
      content: Messages.linkExpired,
      components: [],
    });
  }

  private async onTicketSubmitted(interaction: ModalSubmitInteraction) {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });

    const link = await this.api.getLink(interaction.user.id);
    if (!link) {
      await interaction.editReply({
        content: Messages.linkGone,
      });
      return;
    }

    if (this.creating.has(interaction.user.id)) {
      await interaction.editReply({ content: Messages.ticketAlreadyCreating });
      return;
    }
    this.creating.add(interaction.user.id);
    try {
      const open = await this.discord.listOpenTicketThreads(interaction.user.id);
      if (open.length >= env.TICKET_USER_LIMIT) {
        await interaction.editReply({
          content: Messages.ticketLimit(open.length, open.map((thread) => `<#${thread.id}>`).join(' ')),
        });
        return;
      }

      const description = interaction.fields.getTextInputValue(ComponentId.TicketDescription);
      const thread = await this.openTicket(interaction.user, description);
      await interaction.editReply({ content: Messages.ticketReady(thread.id) });
    } finally {
      this.creating.delete(interaction.user.id);
    }
  }

  private async onStaffTicket(interaction: ChatInputCommandInteraction) {
    if (!isStaff(interaction)) {
      await interaction.reply({ content: Messages.staffOnlyTickets, flags: MessageFlags.Ephemeral });
      return;
    }

    const target = interaction.options.getUser('user', true);
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });

    if (this.creating.has(target.id)) {
      await interaction.editReply({ content: Messages.ticketAlreadyCreatingStaff });
      return;
    }
    this.creating.add(target.id);
    try {
      const open = await this.discord.listOpenTicketThreads(target.id);
      if (open.length >= env.TICKET_USER_LIMIT) {
        await interaction.editReply({
          content: Messages.ticketLimitStaff(target.id, open.length, open.map((thread) => `<#${thread.id}>`).join(' ')),
        });
        return;
      }

      const thread = await this.openTicket(target, Messages.ticketOpenedByStaff(interaction.user.id));
      await interaction.editReply({ content: Messages.ticketReadyStaff(thread.id) });
    } finally {
      this.creating.delete(target.id);
    }
  }

  private async openTicket(user: User, description: string): Promise<ThreadChannel> {
    const suffix = this.ticketSuffix(user.username, user.id);
    const thread = await this.discord.createTicketThread(`ticket-${suffix}`, user.id);

    const seed = await thread.send({
      content: `<@${user.id}> <@&${env.DISCORD_STAFF_ROLE_ID}>`,
      embeds: [new EmbedBuilder().setTitle(Messages.ticketEmbedTitle).setDescription(description)],
      components: [this.buttonRow(ComponentId.CloseTicket, Messages.closeTicketButton, ButtonStyle.Danger)],
    });
    const attachmentsAvailable = await this.discord.canSendTicketAttachments(user.id).catch((error: unknown) => {
      this.logger.warn(error, 'could not check ticket attachment permissions');
      return false;
    });
    if (!attachmentsAvailable) {
      await thread.send({ content: Messages.ticketAttachmentsUnavailable, allowedMentions: { parse: [] } });
    }

    const link = await this.api.getLink(user.id).catch((error: unknown) => {
      this.logger.error(error, 'failed to look up link for staff note');
      return null;
    });
    if (link) {
      this.syncUsername(link, user);
    }
    const summary = link
      ? await this.api.getUserSummary(link.userId).catch((error: unknown) => {
          this.logger.error(error, 'failed to fetch user summary');
          return null;
        })
      : null;
    const versions = link
      ? await this.columbo.getVersions(link.userId).catch((error: unknown) => {
          this.logger.warn(error, 'failed to fetch account versions');
          return null;
        })
      : null;
    const note = `${this.staffNote(link, summary)}\n${link ? formatVersions(versions) : Messages.versionsNoAccount}`;
    const staff = await this.discord.createStaffThread(
      `staff-${suffix}`,
      `<@&${env.DISCORD_STAFF_ROLE_ID}>\nCustomer ticket: <#${thread.id}>\n${note}`,
      [this.buttonRow(ComponentId.Investigate, Messages.investigateButton)],
    );

    void this.freshdeskSync
      .onTicketOpened({
        threadId: thread.id,
        seedMessageId: seed.id,
        staffThreadId: staff.thread.id,
        staffSeedMessageId: staff.seed.id,
        discordUserId: user.id,
        username: user.username,
        userId: link?.userId ?? null,
        description,
        staffNote: note,
      })
      .catch((error: unknown) => this.logger.error(error, 'failed to open the freshdesk ticket'));

    if (link) {
      void this.columbo
        .requestInvestigation({
          ticketThreadId: thread.id,
          staffThreadId: staff.thread.id,
          discordUserId: user.id,
          username: user.username,
          userId: link.userId,
          description,
        })
        .catch((error: unknown) => this.logger.error(error, 'failed to request an investigation'));
    }

    return thread;
  }

  async postStaffNote(staffThreadId: string, content: string): Promise<void> {
    const thread = await this.discord.getThreadById(staffThreadId);
    if (thread.parentId !== env.DISCORD_SUPPORT_CHANNEL_ID || !thread.name.startsWith('staff-')) {
      throw new BadRequestException(`thread ${staffThreadId} is not a staff thread`);
    }
    await this.discord.sendToThread(staffThreadId, {
      embeds: [new EmbedBuilder().setTitle(Messages.investigationTitle).setDescription(content.slice(0, 4096))],
    });
  }

  private async onInvestigationRequested(
    interaction: ButtonInteraction | ChatInputCommandInteraction | ModalSubmitInteraction,
  ): Promise<void> {
    if (!isStaff(interaction)) {
      await interaction.reply({ content: Messages.investigationStaffOnly, flags: MessageFlags.Ephemeral });
      return;
    }
    const staff = interaction.channel;
    if (
      !(staff instanceof ThreadChannel) ||
      staff.parentId !== env.DISCORD_SUPPORT_CHANNEL_ID ||
      !staff.name.startsWith('staff-') ||
      staff.locked
    ) {
      await interaction.reply({ content: Messages.investigationNotAStaffThread, flags: MessageFlags.Ephemeral });
      return;
    }
    if (!this.columbo.enabled) {
      await interaction.reply({ content: Messages.investigationUnavailable, flags: MessageFlags.Ephemeral });
      return;
    }
    const prompt = interaction.isModalSubmit()
      ? interaction.fields.getTextInputValue(ComponentId.InvestigationPrompt).trim()
      : interaction.isChatInputCommand()
        ? interaction.options.getString('prompt')?.trim()
        : undefined;
    if (prompt === undefined && !interaction.isModalSubmit()) {
      await interaction.showModal(
        new ModalBuilder()
          .setCustomId(ComponentId.InvestigationModal)
          .setTitle(Messages.investigationModalTitle)
          .addComponents(
            new ActionRowBuilder<TextInputBuilder>().addComponents(
              new TextInputBuilder()
                .setCustomId(ComponentId.InvestigationPrompt)
                .setLabel(Messages.investigationPromptLabel)
                .setStyle(TextInputStyle.Paragraph)
                .setRequired(false)
                .setMaxLength(INVESTIGATION_PROMPT_MAX_LENGTH),
            ),
          ),
      );
      return;
    }
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    const mapping = await this.api.getTicketByThread(staff.id);
    if (mapping && (mapping.closedAt || mapping.staffThreadId !== staff.id)) {
      await interaction.editReply({ content: Messages.investigationMissingTicket });
      return;
    }
    const ticket = mapping
      ? await this.discord.getThreadById(mapping.threadId)
      : await this.discord.findSupportThreadByName(staff.name.replace(/^staff-/, 'ticket-'));
    if (!ticket || ticket.locked) {
      await interaction.editReply({ content: Messages.investigationMissingTicket });
      return;
    }
    const opening = await this.discord.getTicketOpening(ticket.id);
    if (!opening) {
      await interaction.editReply({ content: Messages.investigationMissingTicket });
      return;
    }
    const link = mapping?.userId
      ? { userId: mapping.userId, discordUsername: '' }
      : await this.api.getLink(opening.discordUserId);
    if (!link) {
      await interaction.editReply({ content: Messages.investigationNoAccount });
      return;
    }
    const messages = await this.discord.listThreadMessages(ticket.id);
    const conversation = messages
      .flatMap((message) => {
        const mirror = message.author.bot
          ? message.embeds?.find(
              (embed) =>
                embed.author?.name === Messages.viaEmailAuthor || embed.author?.name.endsWith('(FUTO support)'),
            )
          : undefined;
        if (message.author.bot && !mirror) {
          return [];
        }
        const attachments = [...message.attachments.values()].map((attachment) => attachment.url).join('\n');
        return [
          `${message.createdAt.toISOString()} ${mirror?.author?.name ?? message.author.username}: ${mirror?.description ?? message.content}${attachments ? `\n${attachments}` : ''}`,
        ];
      })
      .join('\n')
      .slice(-INVESTIGATION_CONTEXT_MAX_LENGTH);
    await this.columbo.requestInvestigation({
      ticketThreadId: ticket.id,
      staffThreadId: staff.id,
      discordUserId: opening.discordUserId,
      username: link.discordUsername || opening.discordUserId,
      userId: link.userId,
      description: opening.description,
      prompt: (prompt ?? '').slice(0, INVESTIGATION_PROMPT_MAX_LENGTH),
      conversation,
      requestedBy: interaction.user.id,
    });
    await this.discord
      .sendToThread(staff.id, {
        content: Messages.investigationRequested(interaction.user.id),
        ...(prompt ? { embeds: [new EmbedBuilder().setDescription(prompt)] } : {}),
        allowedMentions: { parse: [] },
      })
      .catch((error: unknown) => this.logger.warn(error, 'could not announce the queued investigation'));
    await interaction.editReply({ content: Messages.investigationQueued });
  }

  private async onStaffNotesRequested(interaction: ChatInputCommandInteraction) {
    if (!isStaff(interaction)) {
      await interaction.reply({ content: Messages.staffOnlyNotes, flags: MessageFlags.Ephemeral });
      return;
    }

    const thread = interaction.channel;
    if (
      !(thread instanceof ThreadChannel) ||
      thread.parentId !== env.DISCORD_SUPPORT_CHANNEL_ID ||
      !thread.name.startsWith('ticket-')
    ) {
      await interaction.reply({ content: Messages.notATicket, flags: MessageFlags.Ephemeral });
      return;
    }

    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    const staffThread = await this.discord.findSupportThreadByName(thread.name.replace(/^ticket-/, 'staff-'), true);
    await interaction.editReply({
      content: staffThread ? Messages.staffNotesLink(staffThread.id) : Messages.staffNotesMissing,
    });
  }

  private async onCloseRequested(interaction: ButtonInteraction) {
    if (!isStaff(interaction)) {
      await interaction.reply({ content: Messages.staffOnlyClose, flags: MessageFlags.Ephemeral });
      return;
    }

    const thread = interaction.channel;
    if (
      !(thread instanceof ThreadChannel) ||
      thread.parentId !== env.DISCORD_SUPPORT_CHANNEL_ID ||
      !thread.name.startsWith('ticket-')
    ) {
      await interaction.reply({ content: Messages.notATicket, flags: MessageFlags.Ephemeral });
      return;
    }

    await interaction.deferReply();
    await interaction.editReply({ content: Messages.ticketClosedBy(interaction.user.id) });

    const staffThread = await this.discord.findSupportThreadByName(thread.name.replace(/^ticket-/, 'staff-'));
    if (staffThread) {
      await this.discord.closeThread(staffThread);
    }
    await this.discord.closeThread(thread);

    void this.freshdeskSync
      .onTicketClosed(thread.id)
      .catch((error: unknown) => this.logger.error(error, 'failed to resolve the freshdesk ticket'));
  }

  private syncUsername(link: DiscordLink, user: User) {
    if (!user.username || link.discordUsername === user.username) {
      return;
    }
    void this.api
      .updateLinkUsername(user.id, user.username)
      .catch((error: unknown) => this.logger.warn(error, 'failed to sync discord username'));
  }

  private ticketSuffix(username: string, discordUserId: string): string {
    return `${username.toLowerCase().replaceAll(/[^a-z0-9-]/g, '')}-${discordUserId.slice(-4)}-${Date.now().toString(36)}`;
  }

  private staffNote(link: DiscordLink | null, summary: UserSummary | null): string {
    const lines = [Messages.staffNoteHeader];
    if (!link) {
      lines.push(Messages.staffNoteNoLink);
      return lines.join('\n');
    }
    const grafanaBase = env.GRAFANA_URL.replace(/\/+$/, '');
    lines.push(`Grafana: ${grafanaBase}/d/yucca-per-user?var-user=${encodeURIComponent(link.userId)}`);
    if (summary) {
      lines.push(
        `Account: ${summary.name} <${summary.email}>`,
        `Created: ${summary.createdAt.toISOString()}`,
        `Connections: ${summary.connectionCount} · Repositories: ${summary.repositoryCount}`,
        `Last seen: ${summary.lastSeenAt ? summary.lastSeenAt.toISOString() : 'never'}`,
      );
    }
    return lines.join('\n');
  }

  private buttonRow(id: ComponentId, label: string, style: ButtonStyle = ButtonStyle.Primary) {
    return new ActionRowBuilder<ButtonBuilder>().addComponents(
      new ButtonBuilder().setCustomId(id).setLabel(label).setStyle(style),
    );
  }
}
