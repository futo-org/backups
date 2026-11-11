import { jest } from '@jest/globals';
import { ConfigUpdateRequestDto } from '../dto/config.dto.js';
import { ConnectionsSource } from '../enum.js';
import { UNTHROTTLED } from '../proxy/resticProxy.js';
import { ResticPlacement } from '../repositories/config.repository.js';
import { ConfigService } from './config.service.js';

const unplaced = { siteCode: null, storageClusterCode: null };

const makeService = ({
  override = null,
  repositories = [],
  automatic = (_placement: ResticPlacement) =>
    Promise.resolve({ connections: 6, source: ConnectionsSource.WellKnown as ConnectionsSource }),
}: {
  override?: number | null;
  repositories?: ResticPlacement[];
  automatic?: (placement: ResticPlacement) => Promise<{ connections: number; source: ConnectionsSource }>;
} = {}) => {
  const config = {
    getConnectionsOverride: jest.fn(() => Promise.resolve(override)),
    setConnectionsOverride: jest.fn(() => Promise.resolve()),
    getAutomaticConnections: jest.fn(automatic),
    setThrottle: jest.fn(() => Promise.resolve()),
  };
  const moduleConfig = { get: jest.fn(() => ({})), update: jest.fn() };
  const repository = { getAll: jest.fn(() => Promise.resolve(repositories)) };

  const service = new ConfigService(config as never, moduleConfig as never, repository as never);

  return { service, config, moduleConfig };
};

describe(ConfigService.name, () => {
  it('resolves the automatic value for the placement of a local repository', async () => {
    const placement = { siteCode: 'father', storageClusterCode: 'father-spice' };
    const { service, config } = makeService({ repositories: [unplaced, placement] });

    await expect(service.getConfig()).resolves.toEqual({
      bandwidth: UNTHROTTLED,
      connections: {
        override: null,
        automatic: 6,
        effective: 6,
        source: ConnectionsSource.WellKnown,
        min: 1,
        max: 128,
      },
    });

    expect(config.getAutomaticConnections).toHaveBeenCalledWith(placement);
  });

  it('falls back to the global value when the placement is no longer published', async () => {
    const { service, config } = makeService({
      repositories: [{ siteCode: 'gone', storageClusterCode: null }],
      automatic: (placement) =>
        placement.siteCode
          ? Promise.reject(new Error(`Unknown site '${placement.siteCode}'`))
          : Promise.resolve({ connections: 4, source: ConnectionsSource.Cores }),
    });

    await expect(service.getConfig()).resolves.toMatchObject({
      connections: { automatic: 4, effective: 4, source: ConnectionsSource.Cores },
    });

    expect(config.getAutomaticConnections).toHaveBeenLastCalledWith(unplaced);
  });

  it('reports a stored override as the effective value', async () => {
    const { service } = makeService({ override: 20 });

    await expect(service.getConfig()).resolves.toMatchObject({
      connections: { override: 20, automatic: 6, effective: 20, source: ConnectionsSource.Override },
    });
  });

  it.each<[string, ConfigUpdateRequestDto, number | null]>([
    ['sets', { connections: 10 }, 10],
    ['clears', { connections: null }, null],
  ])('%s the override without touching the throttle', async (_, dto, expected) => {
    const { service, config, moduleConfig } = makeService();

    await service.updateConfig(dto);

    expect(config.setConnectionsOverride).toHaveBeenCalledWith(expected);
    expect(config.setThrottle).not.toHaveBeenCalled();
    expect(moduleConfig.update).not.toHaveBeenCalled();
  });

  it('leaves the override alone when only the throttle changes', async () => {
    const { service, config } = makeService();

    await service.updateConfig({ bandwidth: { bytesPerSec: 1000 } });

    expect(config.setConnectionsOverride).not.toHaveBeenCalled();
    expect(config.setThrottle).toHaveBeenCalledWith({ bytesPerSec: 1000 });
  });
});
