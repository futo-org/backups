import { DynamicModule, FactoryProvider, Module, ModuleMetadata } from '@nestjs/common';
import { APP_GUARD, APP_INTERCEPTOR } from '@nestjs/core';
import { EventEmitterModule } from '@nestjs/event-emitter';
import { JwtModule } from '@nestjs/jwt';
import { ScheduleModule } from '@nestjs/schedule';
import Database from 'better-sqlite3';
import { type SqliteDatabase, SqliteDialect } from 'kysely';
import { KyselyModule } from 'nestjs-kysely';
import { existsSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolve } from 'node:path';
import { AuthController } from './controllers/auth.controller.js';
import { BackendController } from './controllers/backend.controller.js';
import { ConfigController } from './controllers/config.controller.js';
import { DevelopmentController } from './controllers/development.controller.js';
import { FilesystemController } from './controllers/filesystem.controller.js';
import { IntegrationsController } from './controllers/integrations.controller.js';
import { OnboardingController } from './controllers/onboarding.controller.js';
import { RepositoryController } from './controllers/repository.controller.js';
import { RunHistoryController } from './controllers/runHistory.controller.js';
import { RunningTasksController } from './controllers/runningTasks.controller.js';
import { ScheduleController } from './controllers/schedule.controller.js';
import { EventsGateway } from './events/events.gateway.js';
import { TelemetryErrorInterceptor } from './interceptors/telemetry-error.interceptor.js';
import { SessionGuard } from './middleware/session.guard.js';
import { type ModuleConfig, ModuleConfigProvider } from './moduleConfig.js';
import { ResticProxyPool } from './proxy/resticProxyPool.js';
import { BackendRepository } from './repositories/backend.repository.js';
import { BootstrapRepository } from './repositories/bootstrap.repository.js';
import { ConfigRepository } from './repositories/config.repository.js';
import { DatabaseRepository } from './repositories/database.repository.js';
import { LockRepository } from './repositories/lock.repository.js';
import { LoggingRepository } from './repositories/logging.repository.js';
import { ModuleConfigRepository } from './repositories/moduleConfig.repository.js';
import { RepositoryRepository } from './repositories/repository.repository.js';
import { RepositoryIntegrationImmichRepository } from './repositories/repositoryIntegrationImmich.repository.js';
import { RepositoryLocalMetricsRepository } from './repositories/repositoryLocalMetrics.repository.js';
import { RepositoryPathRepository } from './repositories/repositoryPath.repository.js';
import { ResticRepository } from './repositories/restic.repository.js';
import { RunHistoryRepository } from './repositories/runHistory.repository.js';
import { RunningTasksRepository } from './repositories/runningTasks.repository.js';
import { ScheduleRepository } from './repositories/schedule.repository.js';
import { StorageRepository } from './repositories/storage.repository.js';
import { AuthService } from './services/auth.service.js';
import { BackendService } from './services/backend.service.js';
import { BootstrapService } from './services/bootstrap.service.js';
import { ConfigService } from './services/config.service.js';
import { DevelopmentService } from './services/development.service.js';
import { FilesystemService } from './services/filesystem.service.js';
import { IntegrationsService } from './services/integrations.service.js';
import { OnboardingService } from './services/onboarding.service.js';
import { RepositoryService } from './services/repository.service.js';
import { RunHistoryService } from './services/runHistory.service.js';
import { RunningTasksService } from './services/runningTasks.service.js';
import { ScheduleService } from './services/schedule.service.js';
import { SessionService } from './services/session.service.js';
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
  OnboardingController,
  RepositoryController,
  RunHistoryController,
  RunningTasksController,
  ScheduleController,
];

export const repositories = [
  BackendRepository,
  BootstrapRepository,
  ConfigRepository,
  DatabaseRepository,
  LockRepository,
  LoggingRepository,
  ModuleConfigRepository,
  RepositoryRepository,
  RepositoryIntegrationImmichRepository,
  RepositoryLocalMetricsRepository,
  RepositoryPathRepository,
  ResticRepository,
  RunHistoryRepository,
  RunningTasksRepository,
  ScheduleRepository,
  StorageRepository,
];

export const services = [
  AuthService,
  BackendService,
  BootstrapService,
  ConfigService,
  DevelopmentService,
  FilesystemService,
  IntegrationsService,
  OnboardingService,
  RepositoryService,
  RunHistoryService,
  RunningTasksService,
  ScheduleService,
  SessionService,
  TelemetryService,
  YuccaService,
];

export function openStateDatabase(
  config: Pick<ModuleConfig, 'statePath'>,
  logger = LoggingRepository.create('State'),
): SqliteDatabase {
  mkdirSync(config.statePath, { recursive: true });

  const databasePath = resolve(config.statePath, 'state.sqlite3');

  if (existsSync(databasePath)) {
    logger.log(`Opened existing state database at ${databasePath}`);
  } else {
    logger.warn(`No state database at ${databasePath}, creating a new one`);
  }

  const database = new Database(databasePath);
  database.pragma('journal_mode = WAL');
  database.pragma('wal_autocheckpoint = 1');

  return database;
}

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
            dialect: new SqliteDialect({ database: openStateDatabase(config) }),
          }),
        }),
        EventEmitterModule.forRoot(),
        JwtModule.register({}),
        ScheduleModule.forRoot(),
      ],
      controllers,
      providers: [
        { provide: APP_INTERCEPTOR, useClass: TelemetryErrorInterceptor },
        { provide: APP_GUARD, useClass: SessionGuard },
        EventsGateway,
        ResticProxyPool,
        ...repositories,
        ...services,
      ],
      exports: [YuccaService],
    };
  }
}
