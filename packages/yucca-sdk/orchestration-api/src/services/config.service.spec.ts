import { jest } from '@jest/globals';
import { ConfigUpdateRequestDto } from '../dto/config.dto.js';
import { ConnectionsSource } from '../enum.js';
import { UNTHROTTLED } from '../proxy/resticProxy.js';
import { ResticPlacement } from '../repositories/config.repository.js';
import { ConfigService } from './config.service.js';

const unplaced = { siteCode: null, storageClusterCode: null };
const spice = { siteCode: 'father', storageClusterCode: 'father-spice' };
const salt = { siteCode: 'father', storageClusterCode: 'father-salt' };

type Automatic = { connections: number; source: ConnectionsSource };

const byCluster: Record<string, Automatic> = {
  'father-spice': { connections: 6, source: ConnectionsSource.WellKnown },
  'father-salt': { connections: 12, source: ConnectionsSource.WellKnown },
};

const makeService = ({
  override = null,
  repositories = [],
  automatic = ({ storageClusterCode }: ResticPlacement) =>
    Promise.resolve(byCluster[storageClusterCode ?? ''] ?? { connections: 4, source: ConnectionsSource.Cores }),
}: {
  override?: number | null;
  repositories?: ResticPlacement[];
  automatic?: (placement: ResticPlacement) => Promise<Automatic>;
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
  it('resolves the global automatic value without local repositories', async () => {
    const { service } = makeService();

    await expect(service.getConfig()).resolves.toEqual({
      bandwidth: UNTHROTTLED,
      connections: {
        override: null,
        placements: [{ ...unplaced, automatic: 4, effective: 4, source: ConnectionsSource.Cores }],
        min: 1,
        max: 128,
      },
    });
  });

  it('reports each distinct repository placement with its own automatic value', async () => {
    const { service } = makeService({ repositories: [spice, salt, spice] });

    await expect(service.getConfig()).resolves.toMatchObject({
      connections: {
        placements: [
          { ...spice, automatic: 6, effective: 6, source: ConnectionsSource.WellKnown },
          { ...salt, automatic: 12, effective: 12, source: ConnectionsSource.WellKnown },
        ],
      },
    });
  });

  it('falls back to the global value when a placement is no longer published', async () => {
    const gone = { siteCode: 'gone', storageClusterCode: null };
    const { service, config } = makeService({
      repositories: [gone],
      automatic: (placement) =>
        placement.siteCode
          ? Promise.reject(new Error(`Unknown site '${placement.siteCode}'`))
          : Promise.resolve({ connections: 4, source: ConnectionsSource.Cores }),
    });

    await expect(service.getConfig()).resolves.toMatchObject({
      connections: { placements: [{ ...gone, automatic: 4, effective: 4, source: ConnectionsSource.Cores }] },
    });

    expect(config.getAutomaticConnections).toHaveBeenLastCalledWith(unplaced);
  });

  it('reports a stored override as the effective value for every placement', async () => {
    const { service } = makeService({ override: 20, repositories: [spice, salt] });

    await expect(service.getConfig()).resolves.toMatchObject({
      connections: {
        override: 20,
        placements: [
          { ...spice, automatic: 6, effective: 20, source: ConnectionsSource.Override },
          { ...salt, automatic: 12, effective: 20, source: ConnectionsSource.Override },
        ],
      },
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
