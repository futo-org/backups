import { INestApplication } from '@nestjs/common';
import { DiscoveryModule } from '@nestjs/core';
import { EventEmitterModule } from '@nestjs/event-emitter';
import { JwtModule } from '@nestjs/jwt';
import { ScheduleModule } from '@nestjs/schedule';
import { Test, TestingModule } from '@nestjs/testing';
import { Kysely } from 'kysely';
import { PGliteDialect } from 'kysely-pglite-dialect';
import { KYSELY_MODULE_CONNECTION_TOKEN, KyselyModule } from 'nestjs-kysely';
import { randomUUID } from 'node:crypto';
import { mkdir, mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createPGlite } from '../src/bin/pglite.js';
import { BackendType } from '../src/enum.js';
import { EventsGateway, GatewayEvent } from '../src/events/events.gateway.js';
import { ModuleConfigProvider } from '../src/moduleConfig.js';
import { controllers, jobs, repositories, services } from '../src/orchestrationApi.module.js';
import { BackendRepository } from '../src/repositories/backend.repository.js';
import { ConfigRepository } from '../src/repositories/config.repository.js';
import { DatabaseRepository } from '../src/repositories/database.repository.js';
import { LoggingRepository } from '../src/repositories/logging.repository.js';
import { ResticRepository } from '../src/repositories/restic.repository.js';
import { StorageRepository } from '../src/repositories/storage.repository.js';
import type { DB } from '../src/schema/index.js';
import { newResticRepositoryMock, RepositoryInterface } from './mocks.js';

type GatewayListener = (event: GatewayEvent) => void;

export interface TestEventBus {
  emit: GatewayListener;
  on: (listener: GatewayListener) => void;
  off: (listener: GatewayListener) => void;
}

function createEventBus(): TestEventBus {
  const listeners = new Set<GatewayListener>();
  return {
    emit: (event) => {
      for (const listener of listeners) {
        listener(event);
      }
    },
    on: (listener) => {
      listeners.add(listener);
    },
    off: (listener) => {
      listeners.delete(listener);
    },
  };
}

export interface TestContext {
  app: INestApplication;
  module: TestingModule;
  gateway: EventsGateway;
  events: TestEventBus;
  db: Kysely<DB>;
  resticMock: jest.Mocked<RepositoryInterface<ResticRepository>>;
  backendId: string;
  statePath: string;
  backendPath: string;
}

export async function createTestingModule(): Promise<TestContext> {
  const statePath = await mkdtemp(join(tmpdir(), 'yucca-test-'));
  const backendPath = await mkdtemp(join(tmpdir(), 'yucca-backend-'));
  await mkdir(join(statePath, 'logs'), { recursive: true });

  const resticMock = newResticRepositoryMock();
  const events = createEventBus();

  const moduleFixture: TestingModule = await Test.createTestingModule({
    imports: [
      KyselyModule.forRoot([
        {
          namespace: 'orchestrator',
          dialect: new PGliteDialect(await createPGlite()),
        },
      ]),
      EventEmitterModule.forRoot(),
      JwtModule.register({}),
      ScheduleModule.forRoot(),
      DiscoveryModule,
    ],
    controllers,
    providers: [
      {
        provide: ModuleConfigProvider,
        useValue: {
          statePath,
          requireLock: false,
          requireWsAuth: false,
          onInternalEvent: events.emit,
        },
      },
      EventsGateway,
      ...repositories,
      ...services,
      ...jobs,
    ],
  })
    .overrideProvider(ResticRepository)
    .useValue(resticMock)
    .compile();

  const app = moduleFixture.createNestApplication();
  await app.init();

  const backendId = randomUUID();
  await moduleFixture.get(BackendRepository).updateBackend(backendId, {
    type: BackendType.Local,
    path: backendPath,
  });

  return {
    app,
    module: moduleFixture,
    gateway: moduleFixture.get(EventsGateway),
    events,
    db: moduleFixture.get<Kysely<DB>>(KYSELY_MODULE_CONNECTION_TOKEN('orchestrator')),
    resticMock,
    backendId,
    statePath,
    backendPath,
  };
}

export type BootedConfig = {
  config: ConfigRepository;
  db: Kysely<DB>;
  close: () => Promise<void>;
};

export async function bootConfig(statePath: string, dataDir = join(statePath, 'pglite')): Promise<BootedConfig> {
  const moduleFixture = await Test.createTestingModule({
    imports: [
      KyselyModule.forRoot([{ namespace: 'orchestrator', dialect: new PGliteDialect(await createPGlite(dataDir)) }]),
    ],
    providers: [
      { provide: ModuleConfigProvider, useValue: { statePath } },
      LoggingRepository,
      StorageRepository,
      DatabaseRepository,
      ConfigRepository,
    ],
  }).compile();

  await moduleFixture.get(DatabaseRepository).runMigrations();

  return {
    config: moduleFixture.get(ConfigRepository),
    db: moduleFixture.get<Kysely<DB>>(KYSELY_MODULE_CONNECTION_TOKEN('orchestrator')),
    close: () => moduleFixture.close(),
  };
}

export function waitForEvent(
  events: TestEventBus,
  type: GatewayEvent['type'],
  predicate: (event: GatewayEvent) => boolean = () => true,
): Promise<GatewayEvent> {
  return new Promise((resolve) => {
    const onEvent = (event: GatewayEvent) => {
      if (event.type === type && predicate(event)) {
        events.off(onEvent);
        resolve(event);
      }
    };
    events.on(onEvent);
  });
}

export async function waitFor(predicate: () => boolean, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) {
      throw new Error('Timed out waiting for condition');
    }
    await new Promise((resolve) => setImmediate(resolve));
  }
}
