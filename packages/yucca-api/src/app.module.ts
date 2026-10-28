import { LoggerRepository, LoggingInterceptor, OtelModule, WideContextRepository } from '@common/server/otel';
import { Module, Provider } from '@nestjs/common';
import { APP_GUARD, APP_INTERCEPTOR, APP_PIPE } from '@nestjs/core';
import { JwtModule } from '@nestjs/jwt';
import { KyselyModule } from 'nestjs-kysely';
import { ZodSerializerInterceptor, ZodValidationPipe } from 'nestjs-zod';
import { AuthController } from './controllers/auth.controller.js';
import { BillingController } from './controllers/billing.controller.js';
import { BillingInternalController } from './controllers/billingInternal.controller.js';
import { ConnectionController } from './controllers/connection.controller.js';
import { DiscordController } from './controllers/discord.controller.js';
import { DiscordInternalController } from './controllers/discordInternal.controller.js';
import { MetaController } from './controllers/meta.controller.js';
import { MetricsController } from './controllers/metrics.controller.js';
import { RepositoryController } from './controllers/repository.controller.js';
import { SupportLogController } from './controllers/supportLog.controller.js';
import { SupportLogInternalController } from './controllers/supportLogInternal.controller.js';
import { env } from './env.js';
import { AuthGuard } from './middleware/auth.guard.js';
import { BillingRepository } from './repositories/billing.repository.js';
import { ConnectionRepository } from './repositories/connection.repository.js';
import { CryptoRepository } from './repositories/crypto.repository.js';
import { DatabaseRepository } from './repositories/database.repository.js';
import { DiscordRepository } from './repositories/discord.repository.js';
import { FutopayRepository } from './repositories/futopay.repository.js';
import { OidcRepository } from './repositories/oidc.repository.js';
import { RepositoryRepository } from './repositories/repository.repository.js';
import { RepositoryMetricsRepository } from './repositories/repositoryMetrics.repository.js';
import { RepositoryMetricsHistoryRepository } from './repositories/repositoryMetricsHistory.repository.js';
import { SessionRepository } from './repositories/session.repository.js';
import { SettingsRepository } from './repositories/settings.repository.js';
import { StorageRepository } from './repositories/storage.repository.js';
import { SupportLogSessionRepository } from './repositories/supportLogSession.repository.js';
import { TicketRepository } from './repositories/ticket.repository.js';
import { TopologyRepository } from './repositories/topology.repository.js';
import { UserRepository } from './repositories/user.repository.js';
import { UserAllowlistRepository } from './repositories/userAllowlist.repository.js';
import { AuthService } from './services/auth.service.js';
import { BillingService } from './services/billing.service.js';
import { ConnectionService } from './services/connection.service.js';
import { DatabaseService } from './services/database.service.js';
import { DiscordService } from './services/discord.service.js';
import { MetaService } from './services/meta.service.js';
import { MetricsService } from './services/metrics.service.js';
import { RepositoryService } from './services/repository.service.js';
import { SupportLogService } from './services/supportLog.service.js';
import { TopologyService } from './services/topology.service.js';
import { getKyselyConfig } from './utils/database.js';

export const imports = [
  JwtModule.register({
    global: true,
    privateKey: env.JWT_PRIVATE_KEY,
    signOptions: { algorithm: 'ES256', expiresIn: env.JWT_EXPIRES_IN },
  }),
  KyselyModule.forRoot(getKyselyConfig()),
];

export const controllers = [
  AuthController,
  BillingController,
  BillingInternalController,
  MetaController,
  ConnectionController,
  DiscordController,
  DiscordInternalController,
  MetricsController,
  RepositoryController,
  SupportLogController,
  SupportLogInternalController,
];

export const providers: Provider[] = [
  WideContextRepository,
  LoggerRepository,
  StorageRepository,
  TopologyRepository,
  SettingsRepository,
  ConnectionRepository,
  DatabaseRepository,
  DiscordRepository,
  CryptoRepository,
  OidcRepository,
  TicketRepository,
  UserRepository,
  UserAllowlistRepository,
  RepositoryRepository,
  RepositoryMetricsRepository,
  RepositoryMetricsHistoryRepository,
  SessionRepository,
  SupportLogSessionRepository,
  BillingRepository,
  FutopayRepository,
  DatabaseService,
  MetaService,
  TopologyService,
  MetricsService,
  RepositoryService,
  AuthService,
  ConnectionService,
  DiscordService,
  SupportLogService,
  BillingService,
  { provide: APP_INTERCEPTOR, useClass: LoggingInterceptor },
  { provide: APP_INTERCEPTOR, useClass: ZodSerializerInterceptor },
  { provide: APP_GUARD, useClass: AuthGuard },
  { provide: APP_PIPE, useClass: ZodValidationPipe },
];

@Module({
  imports: [OtelModule, ...imports],
  controllers,
  providers,
})
export class AppModule {}
