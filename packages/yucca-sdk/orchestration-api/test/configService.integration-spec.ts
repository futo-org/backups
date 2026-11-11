import { jest } from '@jest/globals';
import { EventEmitter2 } from '@nestjs/event-emitter';
import { availableParallelism } from 'node:os';
import { ConfigController } from '../src/controllers/config.controller.js';
import { ConnectionsSource, InternalEvent } from '../src/enum.js';
import { ModuleConfig } from '../src/moduleConfig.js';
import { UNTHROTTLED } from '../src/proxy/resticProxy.js';
import { ConfigRepository } from '../src/repositories/config.repository.js';
import { ModuleConfigRepository } from '../src/repositories/moduleConfig.repository.js';
import { ConfigService } from '../src/services/config.service.js';
import { yuccaWellKnown } from '../src/wellKnown.js';
import { createTestingModule, TestContext } from './testUtils.js';

let ctx: TestContext;

beforeEach(async () => {
  jest.spyOn(yuccaWellKnown, 'getConnections').mockResolvedValue(8);
  ctx = await createTestingModule();
}, 15_000);

afterEach(async () => {
  jest.restoreAllMocks();
  await ctx.app.close();
});

const automaticConnections = {
  override: null,
  automatic: 8,
  effective: 8,
  source: ConnectionsSource.WellKnown,
  min: 1,
  max: 128,
};

describe('Config service', () => {
  const bandwidth = { bytesPerSec: 5_000_000, quietHours: '22:00-06:00' };

  it('reports unthrottled until a throttle is set', async () => {
    await expect(ctx.module.get(ConfigService).getConfig()).resolves.toEqual({
      bandwidth: UNTHROTTLED,
      connections: automaticConnections,
    });
  });

  it('loads a stored throttle on bootstrap', async () => {
    const service = ctx.module.get(ConfigService);
    await ctx.module.get(ConfigRepository).setThrottle(bandwidth);

    await service.bootstrap();

    await expect(service.getConfig()).resolves.toEqual({ bandwidth, connections: automaticConnections });
  });

  it('stores an updated throttle and reports it back', async () => {
    const service = ctx.module.get(ConfigService);

    await expect(service.updateConfig({ bandwidth })).resolves.toEqual({
      bandwidth,
      connections: automaticConnections,
    });

    await expect(service.getConfig()).resolves.toEqual({ bandwidth, connections: automaticConnections });
    await expect(ctx.module.get(ConfigRepository).getThrottle()).resolves.toEqual(bandwidth);
  });

  it('announces an updated throttle to module config listeners', async () => {
    const updates: ModuleConfig[] = [];
    ctx.module.get(EventEmitter2).on(InternalEvent.ModuleConfigUpdated, (config: ModuleConfig) => updates.push(config));

    await ctx.module.get(ConfigService).updateConfig({ bandwidth });

    expect(updates).toEqual([expect.objectContaining({ throttle: bandwidth })]);
    expect(ctx.module.get(ModuleConfigRepository).get().throttle).toEqual(bandwidth);
  });

  it('serves the throttle through the config controller', async () => {
    const controller = ctx.module.get(ConfigController);

    await expect(controller.updateConfig({ bandwidth })).resolves.toEqual({
      bandwidth,
      connections: automaticConnections,
    });

    await expect(controller.getConfig()).resolves.toEqual({ bandwidth, connections: automaticConnections });
  });
});

describe('Connections override', () => {
  const placement = { siteCode: null, storageClusterCode: null };

  it('falls back to the core count when the well-known has no connections math', async () => {
    jest.spyOn(yuccaWellKnown, 'getConnections').mockResolvedValue(undefined);

    await expect(ctx.module.get(ConfigService).getConfig()).resolves.toMatchObject({
      connections: {
        override: null,
        automatic: availableParallelism(),
        effective: availableParallelism(),
        source: ConnectionsSource.Cores,
      },
    });
  });

  it('stores an override that the next restic run uses', async () => {
    const service = ctx.module.get(ConfigService);

    await expect(service.updateConfig({ connections: 3 })).resolves.toEqual({
      bandwidth: UNTHROTTLED,
      connections: { ...automaticConnections, override: 3, effective: 3, source: ConnectionsSource.Override },
    });

    await expect(ctx.module.get(ConfigRepository).getResticOptions(placement)).resolves.toMatchObject({
      connections: 3,
    });
  });

  it('returns to the automatic value when the override is cleared', async () => {
    const service = ctx.module.get(ConfigService);
    await service.updateConfig({ connections: 3 });

    await expect(service.updateConfig({ connections: null })).resolves.toMatchObject({
      connections: automaticConnections,
    });

    await expect(ctx.module.get(ConfigRepository).getConnectionsOverride()).resolves.toBeNull();
    await expect(ctx.module.get(ConfigRepository).getResticOptions(placement)).resolves.toMatchObject({
      connections: 8,
    });
  });

  it('keeps the throttle when only the override changes', async () => {
    const service = ctx.module.get(ConfigService);
    await service.updateConfig({ bandwidth: { bytesPerSec: 1000 } });

    await service.updateConfig({ connections: 12 });

    await expect(ctx.module.get(ConfigRepository).getThrottle()).resolves.toEqual({ bytesPerSec: 1000 });
  });

  it('keeps the override when only the throttle changes', async () => {
    const service = ctx.module.get(ConfigService);
    await service.updateConfig({ connections: 12 });

    await service.updateConfig({ bandwidth: { bytesPerSec: 1000 } });

    await expect(ctx.module.get(ConfigRepository).getConnectionsOverride()).resolves.toBe(12);
  });
});
