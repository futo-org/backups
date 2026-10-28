import { LoggerRepository, LoggingInterceptor, OtelModule, WideContextRepository } from '@common/server/otel';
import { Module } from '@nestjs/common';
import { APP_INTERCEPTOR } from '@nestjs/core';
import { ScheduleModule } from '@nestjs/schedule';
import { KyselyModule } from 'nestjs-kysely';
import { InternalController } from './controllers/internal.controller.js';
import { AllowlistRepository } from './repositories/allowlist.repository.js';
import { BetaInvitesRepository } from './repositories/betaInvites.repository.js';
import { ConnectionMetricsRepository } from './repositories/connectionMetrics.repository.js';
import { FutopayUsageRepository } from './repositories/futopayUsage.repository.js';
import { MeterRepository } from './repositories/meter.repository.js';
import { RepositoryRepository } from './repositories/repository.repository.js';
import { RgwFleetRepository } from './repositories/rgwFleet.repository.js';
import { StorageRepository } from './repositories/storage.repository.js';
import { TopologyRepository } from './repositories/topology.repository.js';
import { UsageReportRepository } from './repositories/usageReport.repository.js';
import { BetaInvitesService } from './services/betaInvites.service.js';
import { InviteMetricsService } from './services/inviteMetrics.service.js';
import { MetricsService } from './services/metrics.service.js';
import { TopologyService } from './services/topology.service.js';
import { UsageReportService } from './services/usageReport.service.js';
import { getKyselyConfig } from './utils/database.js';

export const imports = [KyselyModule.forRoot(getKyselyConfig()), ScheduleModule.forRoot()];

export const providers = [
  WideContextRepository,
  LoggerRepository,
  StorageRepository,
  TopologyRepository,
  RgwFleetRepository,
  MeterRepository,
  RepositoryRepository,
  ConnectionMetricsRepository,
  AllowlistRepository,
  BetaInvitesRepository,
  UsageReportRepository,
  FutopayUsageRepository,
  BetaInvitesService,
  UsageReportService,
  MetricsService,
  InviteMetricsService,
  TopologyService,
  { provide: APP_INTERCEPTOR, useClass: LoggingInterceptor },
];

export const controllers = [InternalController];

@Module({
  imports: [OtelModule, ...imports],
  controllers,
  providers,
})
export class AppModule {}
