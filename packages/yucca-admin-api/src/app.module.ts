import { EmailRepository } from '@common/server/email';
import { LoggerRepository, LoggingInterceptor, OtelModule, WideContextRepository } from '@common/server/otel';
import { Module, Provider } from '@nestjs/common';
import { APP_GUARD, APP_INTERCEPTOR, APP_PIPE } from '@nestjs/core';
import { JwtModule } from '@nestjs/jwt';
import { KyselyModule } from 'nestjs-kysely';
import { ZodSerializerInterceptor, ZodValidationPipe } from 'nestjs-zod';
import { createPublicKey } from 'node:crypto';
import { AllowlistController } from './controllers/allowlist.controller.js';
import { AuthController } from './controllers/auth.controller.js';
import { ColumboController } from './controllers/columbo.controller.js';
import { DiscordInviteController } from './controllers/discordInvite.controller.js';
import { FeaturesController } from './controllers/features.controller.js';
import { RepositoryController } from './controllers/repository.controller.js';
import { SessionController } from './controllers/session.controller.js';
import { SettingsController } from './controllers/settings.controller.js';
import { UserController } from './controllers/user.controller.js';
import { env } from './env.js';
import { AuthGuard } from './middleware/auth.guard.js';
import { ColumboRepository } from './repositories/columbo.repository.js';
import { ConnectionRepository } from './repositories/connection.repository.js';
import { DatabaseRepository } from './repositories/database.repository.js';
import { DiscordInviteRepository } from './repositories/discordInvite.repository.js';
import { DiscordLinkRepository } from './repositories/discordLink.repository.js';
import { FeatureFlagRepository } from './repositories/featureFlag.repository.js';
import { FutoBackupsBotRepository } from './repositories/futoBackupsBot.repository.js';
import { OidcRepository } from './repositories/oidc.repository.js';
import { RepositoryRepository } from './repositories/repository.repository.js';
import { SessionRepository } from './repositories/session.repository.js';
import { SettingsRepository } from './repositories/settings.repository.js';
import { StorageRepository } from './repositories/storage.repository.js';
import { TopologyRepository } from './repositories/topology.repository.js';
import { UserRepository } from './repositories/user.repository.js';
import { UserAllowlistRepository } from './repositories/userAllowlist.repository.js';
import { AllowlistService } from './services/allowlist.service.js';
import { AuthService } from './services/auth.service.js';
import { ColumboService } from './services/columbo.service.js';
import { DatabaseService } from './services/database.service.js';
import { DiscordInviteService } from './services/discordInvite.service.js';
import { FeaturesService } from './services/features.service.js';
import { RepositoryService } from './services/repository.service.js';
import { SessionService } from './services/session.service.js';
import { SettingsService } from './services/settings.service.js';
import { TopologyService } from './services/topology.service.js';
import { UserService } from './services/user.service.js';
import { getKyselyConfig } from './utils/database.js';

export const imports = [
  JwtModule.register({
    global: true,
    privateKey: env.JWT_PRIVATE_KEY,
    // Verification key derived from the signing key: CLI session JWTs are
    // minted and validated by this same service.
    publicKey: createPublicKey(env.JWT_PRIVATE_KEY).export({ type: 'spki', format: 'pem' }).toString(),
    signOptions: { algorithm: 'ES256', expiresIn: env.JWT_EXPIRES_IN },
    verifyOptions: { algorithms: ['ES256'] },
  }),
  KyselyModule.forRoot(getKyselyConfig()),
];

export const controllers = [
  AuthController,
  UserController,
  SessionController,
  RepositoryController,
  AllowlistController,
  ColumboController,
  DiscordInviteController,
  SettingsController,
  FeaturesController,
];

export const providers: Provider[] = [
  WideContextRepository,
  LoggerRepository,
  EmailRepository,
  ColumboRepository,
  DatabaseRepository,
  DiscordInviteRepository,
  DiscordLinkRepository,
  FutoBackupsBotRepository,
  DatabaseService,
  OidcRepository,
  UserRepository,
  UserAllowlistRepository,
  SessionRepository,
  RepositoryRepository,
  SettingsRepository,
  StorageRepository,
  TopologyRepository,
  ConnectionRepository,
  FeatureFlagRepository,
  AllowlistService,
  ColumboService,
  DiscordInviteService,
  AuthService,
  UserService,
  SessionService,
  SettingsService,
  TopologyService,
  RepositoryService,
  FeaturesService,
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
