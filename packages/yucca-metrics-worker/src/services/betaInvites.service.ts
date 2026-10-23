import { LoggerRepository, MetricService } from '@common/server/otel';
import { Injectable, OnApplicationBootstrap } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { Gauge } from '@opentelemetry/api';
import { BetaInvitesRepository } from 'src/repositories/betaInvites.repository.js';

@Injectable()
export class BetaInvitesService implements OnApplicationBootstrap {
  private readonly backedUpAccounts: Gauge;

  constructor(
    private readonly logger: LoggerRepository,
    private readonly invites: BetaInvitesRepository,
    metricService: MetricService,
  ) {
    this.backedUpAccounts = metricService.getGauge('beta_invites_backed_up_accounts', {
      description: 'Non-FUTO accounts with at least one completed backup, assumed invited during beta',
    });
  }

  async onApplicationBootstrap() {
    await this.sync();
  }

  @Cron(CronExpression.EVERY_5_MINUTES)
  async sync() {
    try {
      this.backedUpAccounts.record(await this.invites.getBackedUpAccountCount());
    } catch (error) {
      this.logger.error(error, 'Failed to sync beta invite backup count');
    }
  }
}
