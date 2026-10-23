import { LoggerRepository } from '@common/server/otel';
import { Injectable } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import {
  ActionRowBuilder,
  ButtonBuilder,
  ButtonInteraction,
  ButtonStyle,
  ChatInputCommandInteraction,
  MessageFlags,
  User,
} from 'discord.js';
import { ComponentId } from 'src/enum.js';
import { env } from 'src/env.js';
import { Messages } from 'src/messages.js';
import { DiscordRepository } from 'src/repositories/discord.repository.js';
import { InviteBatch, YuccaApiRepository } from 'src/repositories/yuccaApi.repository.js';
import { isStaff } from 'src/utils/staff.js';

type DropLocation = { guildId: string; channelId: string; messageId: string };

@Injectable()
export class InviteService {
  private readonly dropLocks = new Map<string, Promise<void>>();
  private readonly renderedDrops = new Map<string, string>();
  private readonly endedDrops = new Set<string>();
  private readonly pendingDropLocations = new Map<string, DropLocation>();

  constructor(
    private readonly logger: LoggerRepository,
    private readonly discord: DiscordRepository,
    private readonly api: YuccaApiRepository,
  ) {}

  async onInviteCommand(interaction: ChatInputCommandInteraction): Promise<void> {
    if (!isStaff(interaction)) {
      await interaction.reply({ content: Messages.inviteStaffOnly, flags: MessageFlags.Ephemeral });
      return;
    }

    const target = interaction.options.getUser('user');
    const channel = interaction.options.getChannel('channel');
    if (Boolean(target) === Boolean(channel)) {
      await interaction.reply({
        content: Messages.invitePickOne,
        flags: MessageFlags.Ephemeral,
      });
      return;
    }

    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    if (target) {
      return this.inviteUser(interaction, target);
    }
    return this.postBatch(
      interaction,
      channel!.id,
      interaction.options.getInteger('limit'),
      this.roleMention(interaction),
    );
  }

  private roleMention(interaction: ChatInputCommandInteraction): string | null {
    const role = interaction.options.getRole('mention');
    if (!role) {
      return null;
    }
    // The everyone role's id is the guild id; <@&guildId> renders as a broken
    // "@@everyone" and pings nobody.
    return role.id === interaction.guildId ? '@everyone' : `<@&${role.id}>`;
  }

  private async inviteUser(interaction: ChatInputCommandInteraction, target: User): Promise<void> {
    const result = await this.api.createInvite(target.id, target.username);
    if (result.status !== 'ok') {
      const content =
        result.status === 'invite-used' ? Messages.inviteUsed(target.id) : Messages.inviteAlreadyLinked(target.id);
      await interaction.editReply({ content });
      return;
    }

    const url = this.inviteUrl(result.code);
    const delivered = await this.discord.sendDirectMessage(target.id, {
      content: Messages.inviteDm,
      components: [this.linkRow(url)],
    });
    await interaction.editReply({
      content: delivered ? Messages.inviteSent(target.id) : Messages.inviteDmsClosed(target.id, url),
    });
  }

  private async postBatch(
    interaction: ChatInputCommandInteraction,
    channelId: string,
    limit: number | null,
    mention: string | null,
  ): Promise<void> {
    if (!limit) {
      await interaction.editReply({ content: Messages.inviteLimitRequired });
      return;
    }

    const batchId = await this.api.createInviteBatch(
      interaction.guildId ?? env.DISCORD_GUILD_ID,
      channelId,
      limit,
      interaction.user.id,
    );
    const message = await this.discord.sendMessage(channelId, {
      content: Messages.inviteDrop(limit, mention, interaction.user.id),
      components: [this.claimRow(batchId, Messages.inviteDropButton)],
    });
    const location = {
      guildId: interaction.guildId ?? env.DISCORD_GUILD_ID,
      channelId,
      messageId: message.id,
    };
    this.pendingDropLocations.set(batchId, location);
    await this.withDropLock(batchId, () => this.persistDropLocation(batchId, location));
    await interaction.editReply({ content: Messages.inviteDropPosted(limit, channelId) });
  }

  async onClaimInvite(interaction: ButtonInteraction): Promise<void> {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });

    const batchId = interaction.customId.slice(ComponentId.ClaimInvite.length + 1);
    const result = await this.api.createInvite(interaction.user.id, interaction.user.username, batchId);
    switch (result.status) {
      case 'already-linked': {
        await interaction.editReply({ content: Messages.claimAlreadyLinked });
        return;
      }
      case 'invite-used': {
        await interaction.editReply({ content: Messages.claimInviteUsed });
        return;
      }
      case 'exhausted': {
        await this.refreshDrop(batchId, { channelId: interaction.channelId, messageId: interaction.message.id });
        await interaction.editReply({
          content: Messages.claimExhausted,
        });
        return;
      }
      case 'cancelled': {
        await this.closeDrop(batchId, interaction.channelId, interaction.message.id).catch((error: unknown) =>
          this.logger.warn(error, 'could not close the cancelled invite drop'),
        );
        await interaction.editReply({ content: Messages.claimDropEnded });
        return;
      }
    }

    try {
      await interaction.editReply({
        content: Messages.claimSuccess,
        components: [this.linkRow(this.inviteUrl(result.code))],
      });
    } finally {
      await this.refreshDrop(batchId, { channelId: interaction.channelId, messageId: interaction.message.id });
    }
  }

  async closeDrop(batchId: string, channelId: string, messageId: string): Promise<void> {
    await this.withDropLock(batchId, async () => {
      if (this.endedDrops.has(batchId)) {
        this.pendingDropLocations.delete(batchId);
        return;
      }
      const batch = await this.api
        .getInviteBatch(batchId)
        .catch((error: unknown) => this.logger.warn(error, 'could not look up the ended invite drop'));
      await this.discord.editMessage(channelId, messageId, {
        content: batch
          ? Messages.inviteDropEnded(batch.maxClaims, batch.createdByDiscordUserId)
          : Messages.claimDropEnded,
        components: [this.claimRow(batchId, Messages.inviteDropEndedButton, true)],
        allowedMentions: { parse: [] },
      });
      this.endedDrops.add(batchId);
      this.renderedDrops.delete(batchId);
      this.pendingDropLocations.delete(batchId);
    });
  }

  @Cron(CronExpression.EVERY_MINUTE, { waitForCompletion: true })
  async refreshDrops(): Promise<void> {
    if (!this.discord.enabled || !env.INTERNAL_SECRET) {
      return;
    }
    const batches = await this.api.listInviteBatches().catch((error: unknown) => {
      this.logger.warn(error, 'could not refresh invite drops');
      return [];
    });
    const batchIds = new Set(
      batches.filter((batch) => batch.guildId === env.DISCORD_GUILD_ID).map((batch) => batch.id),
    );
    for (const [batchId, location] of this.pendingDropLocations) {
      if (location.guildId === env.DISCORD_GUILD_ID) {
        batchIds.add(batchId);
      }
    }
    await Promise.all([...batchIds].filter((id) => !this.endedDrops.has(id)).map((id) => this.refreshDrop(id)));
  }

  private async refreshDrop(batchId: string, fallback?: { channelId: string; messageId: string }): Promise<void> {
    await this.withDropLock(batchId, async () => {
      if (this.endedDrops.has(batchId)) {
        this.pendingDropLocations.delete(batchId);
        return;
      }
      const batch = await this.api.getInviteBatch(batchId);
      if (!batch) {
        this.pendingDropLocations.delete(batchId);
        return;
      }
      const location = this.pendingDropLocations.get(batchId) ?? fallback;
      const messageId = batch.messageId ?? location?.messageId;
      if (!messageId) {
        return;
      }
      const channelId = batch.messageId ? batch.channelId : (location?.channelId ?? batch.channelId);
      if (batch.messageId) {
        this.pendingDropLocations.delete(batchId);
      } else {
        const pending = { guildId: batch.guildId, channelId, messageId };
        this.pendingDropLocations.set(batchId, pending);
        await this.persistDropLocation(batchId, pending);
      }
      const state = JSON.stringify([channelId, messageId, batch.remaining, batch.cancelledAt, batch.maxClaims]);
      if (this.renderedDrops.get(batchId) === state) {
        return;
      }
      await this.discord.editMessage(channelId, messageId, this.dropUpdate(batch));
      if (batch.cancelledAt) {
        this.endedDrops.add(batchId);
        this.renderedDrops.delete(batchId);
        this.pendingDropLocations.delete(batchId);
        return;
      }
      this.renderedDrops.set(batchId, state);
    }).catch((error: unknown) => this.logger.warn(error, 'could not refresh the invite drop availability'));
  }

  private async persistDropLocation(batchId: string, location: DropLocation): Promise<void> {
    try {
      await this.api.setInviteBatchMessage(batchId, location.messageId);
      if (this.pendingDropLocations.get(batchId) === location) {
        this.pendingDropLocations.delete(batchId);
      }
    } catch (error) {
      this.logger.warn(error, 'could not record the invite drop message id');
    }
  }

  private dropUpdate(batch: InviteBatch) {
    const cancelled = batch.cancelledAt !== null;
    const label = cancelled
      ? Messages.inviteDropEndedButton
      : batch.remaining === 0
        ? Messages.inviteDropClaimedButton
        : Messages.inviteDropButton;
    return {
      content: cancelled
        ? Messages.inviteDropEnded(batch.maxClaims, batch.createdByDiscordUserId)
        : Messages.inviteDrop(batch.maxClaims, null, batch.createdByDiscordUserId, batch.remaining),
      components: [this.claimRow(batch.id, label, cancelled || batch.remaining === 0)],
      allowedMentions: { parse: [] as const },
    };
  }

  private async withDropLock(batchId: string, action: () => Promise<void>): Promise<void> {
    const previous = this.dropLocks.get(batchId) ?? Promise.resolve();
    const current = previous.catch(() => {}).then(action);
    this.dropLocks.set(batchId, current);
    try {
      await current;
    } finally {
      if (this.dropLocks.get(batchId) === current) {
        this.dropLocks.delete(batchId);
      }
    }
  }

  private inviteUrl(code: string): string {
    return `${env.WEB_URL}/login/invite?token=${code}`;
  }

  private linkRow(url: string) {
    return new ActionRowBuilder<ButtonBuilder>().addComponents(
      new ButtonBuilder().setStyle(ButtonStyle.Link).setLabel(Messages.inviteLinkButton).setURL(url),
    );
  }

  private claimRow(batchId: string, label: string, disabled = false) {
    return new ActionRowBuilder<ButtonBuilder>().addComponents(
      new ButtonBuilder()
        .setCustomId(`${ComponentId.ClaimInvite}:${batchId}`)
        .setLabel(label)
        .setStyle(ButtonStyle.Primary)
        .setDisabled(disabled),
    );
  }
}
