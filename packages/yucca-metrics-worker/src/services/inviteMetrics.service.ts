import { LoggerRepository, MetricService } from '@common/server/otel';
import { Injectable, OnApplicationBootstrap } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { Gauge } from '@opentelemetry/api';
import { env } from 'src/env.js';
import { AllowlistRepository, InviteSources, InviteStates } from 'src/repositories/allowlist.repository.js';

@Injectable()
export class InviteMetricsService implements OnApplicationBootstrap {
  private readonly betaInvites: Gauge;

  constructor(
    private logger: LoggerRepository,
    private allowlist: AllowlistRepository,
    metricService: MetricService,
  ) {
    this.betaInvites = metricService.getGauge('beta_invites', {
      description: 'Beta allowlist entries by invite source and state',
    });
  }

  async onApplicationBootstrap() {
    if (env.NODE_ENV === 'development') {
      await this.sync();
    }
  }

  @Cron(CronExpression.EVERY_5_MINUTES)
  async sync() {
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
}
