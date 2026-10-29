import { DynamicModule, FactoryProvider, Module, ModuleMetadata } from '@nestjs/common';
import { APP_GUARD, APP_INTERCEPTOR, DiscoveryModule } from '@nestjs/core';
import { EventEmitterModule } from '@nestjs/event-emitter';
import { JwtModule } from '@nestjs/jwt';
import { ScheduleModule } from '@nestjs/schedule';
import { KyselyModule } from 'nestjs-kysely';
import { homedir } from 'node:os';
import { resolve } from 'node:path';
import { AuthController } from './controllers/auth.controller.js';
import { BackendController } from './controllers/backend.controller.js';
import { ConfigController } from './controllers/config.controller.js';
import { DevelopmentController } from './controllers/development.controller.js';
import { FilesystemController } from './controllers/filesystem.controller.js';
import { IntegrationsController } from './controllers/integrations.controller.js';
import { JobController } from './controllers/job.controller.js';
import { OnboardingController } from './controllers/onboarding.controller.js';
import { RepositoryController } from './controllers/repository.controller.js';
import { ScheduleController } from './controllers/schedule.controller.js';
import { SupportModeController } from './controllers/supportMode.controller.js';
import { EventsGateway } from './events/events.gateway.js';
import { TelemetryErrorInterceptor } from './interceptors/telemetry-error.interceptor.js';
import { RepositoryBackupJob } from './jobs/repositoryBackup.job.js';
import { RepositoryPruneJob } from './jobs/repositoryPrune.job.js';
import { RepositoryRestoreJob } from './jobs/repositoryRestore.job.js';
import { RepositoryRestoreFromPointJob } from './jobs/repositoryRestoreFromPoint.job.js';
import { RepositorySnapshotForgetJob } from './jobs/repositorySnapshotForget.job.js';
import { RepositorySyncMetricsJob } from './jobs/repositorySyncMetrics.job.js';
import { LegacyStateRepository } from './legacy-sqlite/legacyState.repository.js';
import { SessionGuard } from './middleware/session.guard.js';
import { type ModuleConfig, ModuleConfigProvider } from './moduleConfig.js';
import { ResticProxyPool } from './proxy/resticProxyPool.js';
import { BackendRepository } from './repositories/backend.repository.js';
import { BootstrapRepository } from './repositories/bootstrap.repository.js';
import { ConfigRepository } from './repositories/config.repository.js';
import { DatabaseRepository } from './repositories/database.repository.js';
import { JobRepository } from './repositories/job.repository.js';
import { LockRepository } from './repositories/lock.repository.js';
import { LoggingRepository } from './repositories/logging.repository.js';
import { ModuleConfigRepository } from './repositories/moduleConfig.repository.js';
import { RepositoryRepository } from './repositories/repository.repository.js';
import { RepositoryIntegrationImmichRepository } from './repositories/repositoryIntegrationImmich.repository.js';
import { RepositoryLocalMetricsRepository } from './repositories/repositoryLocalMetrics.repository.js';
import { RepositoryPathRepository } from './repositories/repositoryPath.repository.js';
import { ResticRepository } from './repositories/restic.repository.js';
import { ScheduleRepository } from './repositories/schedule.repository.js';
import { StorageRepository } from './repositories/storage.repository.js';
import { SupportContextRepository } from './repositories/supportContext.repository.js';
import { AuthService } from './services/auth.service.js';
import { BackendService } from './services/backend.service.js';
import { BootstrapService } from './services/bootstrap.service.js';
import { ConfigService } from './services/config.service.js';
import { DevelopmentService } from './services/development.service.js';
import { FilesystemService } from './services/filesystem.service.js';
import { IntegrationsService } from './services/integrations.service.js';
import { JobService } from './services/job.service.js';
import { OnboardingService } from './services/onboarding.service.js';
import { RepositoryService } from './services/repository.service.js';
import { ScheduleService } from './services/schedule.service.js';
import { SessionService } from './services/session.service.js';
import { SupportModeService } from './services/supportMode.service.js';
import { TelemetryService } from './services/telemetry.service.js';
import { YuccaService } from './services/yucca.service.js';
import { yuccaWellKnown } from './wellKnown.js';

export const controllers = [
  AuthController,
  BackendController,
  ConfigController,
  DevelopmentController,
  FilesystemController,
  IntegrationsController,
  JobController,
  OnboardingController,
  RepositoryController,
  ScheduleController,
  SupportModeController,
];

export const repositories = [
  BackendRepository,
  BootstrapRepository,
  ConfigRepository,
  DatabaseRepository,
  JobRepository,
  LegacyStateRepository,
  LockRepository,
  LoggingRepository,
  ModuleConfigRepository,
  RepositoryRepository,
  RepositoryIntegrationImmichRepository,
  RepositoryLocalMetricsRepository,
  RepositoryPathRepository,
  ResticRepository,
  ScheduleRepository,
  StorageRepository,
  SupportContextRepository,
];

export const services = [
  AuthService,
  BackendService,
  BootstrapService,
  ConfigService,
  DevelopmentService,
  FilesystemService,
  IntegrationsService,
  JobService,
  OnboardingService,
  RepositoryService,
  ScheduleService,
  SessionService,
  SupportModeService,
  TelemetryService,
  YuccaService,
];

export const jobs = [
  RepositoryBackupJob,
  RepositoryPruneJob,
  RepositoryRestoreJob,
  RepositoryRestoreFromPointJob,
  RepositorySnapshotForgetJob,
  RepositorySyncMetricsJob,
];

export interface OrchestrationApiModuleAsyncOptions extends Pick<ModuleMetadata, 'imports'> {
  inject?: FactoryProvider['inject'];
  useFactory: (...args: any[]) => Promise<Partial<ModuleConfig>> | Partial<ModuleConfig>;
}

@Module({})
class OrchestrationConfigModule {
  static forRootAsync(options: OrchestrationApiModuleAsyncOptions): DynamicModule {
    return {
      module: OrchestrationConfigModule,
      imports: options.imports ?? [],
      providers: [
        {
          provide: ModuleConfigProvider,
          inject: options.inject ?? [],
          useFactory: async (...args: any[]): Promise<ModuleConfig> => {
            const config = await options.useFactory(...args);
            config.statePath ??= resolve(homedir(), '.yucca');
            yuccaWellKnown.configure(config.wellKnownUrl);
            return config as ModuleConfig;
          },
        },
      ],
      exports: [ModuleConfigProvider],
    };
  }
}

@Module({})
export class OrchestrationApiModule {
  static forRootAsync(options: OrchestrationApiModuleAsyncOptions): DynamicModule {
    const configModule = OrchestrationConfigModule.forRootAsync(options);

    return {
      module: OrchestrationApiModule,
      imports: [
        configModule,
        KyselyModule.forRootAsync({
          namespace: 'orchestrator',
          imports: [configModule],
          inject: [ModuleConfigProvider],
          useFactory: (config: ModuleConfig) => ({
            dialect: config.dialect,
          }),
        }),
        EventEmitterModule.forRoot(),
        JwtModule.register({}),
        ScheduleModule.forRoot(),
        DiscoveryModule,
      ],
      controllers,
      providers: [
        { provide: APP_INTERCEPTOR, useClass: TelemetryErrorInterceptor },
        { provide: APP_GUARD, useClass: SessionGuard },
        EventsGateway,
        ResticProxyPool,
        ...repositories,
        ...services,
        ...jobs,
      ],
      exports: [YuccaService],
    };
  }
}
