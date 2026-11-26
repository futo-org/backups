import { LoggerRepository, MetricService } from '@common/server/otel';
import { Injectable, OnApplicationBootstrap } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { Gauge } from '@opentelemetry/api';
import { env } from 'src/env.js';
import { AllowlistRepository, InviteSources, InviteStates } from 'src/repositories/allowlist.repository.js';
import { InviteCodeRepository } from 'src/repositories/inviteCode.repository.js';

@Injectable()
export class InviteMetricsService implements OnApplicationBootstrap {
  private readonly betaInvites: Gauge;
  private readonly inviteCodeUses: Gauge;
  private readonly inviteCodeMaxUses: Gauge;

  constructor(
    private logger: LoggerRepository,
    private allowlist: AllowlistRepository,
    private inviteCodes: InviteCodeRepository,
    metricService: MetricService,
  ) {
    this.betaInvites = metricService.getGauge('beta_invites', {
      description: 'Beta allowlist entries by invite source and state',
    });
    this.inviteCodeUses = metricService.getGauge('beta_invite_code_uses', {
      description: 'Sign-ups through each reusable invite code',
    });
    this.inviteCodeMaxUses = metricService.getGauge('beta_invite_code_max_uses', {
      description: 'Use limit of each reusable invite code (absent when unlimited)',
    });
  }

  async onApplicationBootstrap() {
    if (env.NODE_ENV === 'development') {
      await this.sync();
    }
  }

  @Cron(CronExpression.EVERY_5_MINUTES)
  async sync() {
    await Promise.all([this.syncAllowlist(), this.syncInviteCodes()]);
  }

  private async syncAllowlist() {
    const counts = await this.allowlist.countInvites().catch((error: unknown) => {
      this.logger.error(error, 'Failed to count beta invites; skipping');
      return null;
    });
    if (!counts) {
      return;
    }

    for (const source of InviteSources) {
      for (const state of InviteStates) {
        const count = counts.find((row) => row.source === source && row.state === state)?.count ?? 0;
        this.betaInvites.record(count, { source, state });
      }
    }
  }

  private async syncInviteCodes() {
    const usages = await this.inviteCodes.countUses().catch((error: unknown) => {
      this.logger.error(error, 'Failed to count invite code uses; skipping');
      return null;
    });
    if (!usages) {
      return;
    }

    for (const { name, uses, maxUses } of usages) {
      this.inviteCodeUses.record(uses, { name });
      if (maxUses !== null) {
        this.inviteCodeMaxUses.record(maxUses, { name });
      }
    }
  }
}
