import { jest } from '@jest/globals';
import { availableParallelism } from 'node:os';
import { ConnectionsSource } from '../enum.js';
import { yuccaWellKnown } from '../wellKnown.js';
import { ConfigRepository } from './config.repository.js';
import { LoggingRepository } from './logging.repository.js';

const storedValue = (value?: unknown) => ({
  selectFrom: jest.fn(() => ({
    where: jest.fn(() => ({
      select: jest.fn(() => ({
        executeTakeFirst: jest.fn(() => Promise.resolve(value === undefined ? undefined : { value })),
      })),
    })),
  })),
});

describe(ConfigRepository.name, () => {
  const db = storedValue();

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('resolves options for a placed repository', async () => {
    const connections = jest.spyOn(yuccaWellKnown, 'getConnections').mockResolvedValue(7);
    const packSize = jest.spyOn(yuccaWellKnown, 'getPackSizeMib').mockResolvedValue(64);
    const repository = new ConfigRepository(db as never, { statePath: '/state' } as never, LoggingRepository.create());

    await expect(
      repository.getResticOptions({ siteCode: 'father', storageClusterCode: 'father-spice' }),
    ).resolves.toEqual({ connections: 7, packSizeMib: 64 });

    expect(connections).toHaveBeenCalledWith(availableParallelism(), 'father', 'father-spice');
    expect(packSize).toHaveBeenCalledWith('father', 'father-spice');
  });

  it('falls back to global config and core count without placement', async () => {
    const connections = jest.spyOn(yuccaWellKnown, 'getConnections').mockResolvedValue(undefined);
    const packSize = jest.spyOn(yuccaWellKnown, 'getPackSizeMib').mockResolvedValue(undefined);
    const repository = new ConfigRepository(db as never, { statePath: '/state' } as never, LoggingRepository.create());

    await expect(repository.getResticOptions({ siteCode: null, storageClusterCode: null })).resolves.toEqual({
      connections: availableParallelism(),
      packSizeMib: undefined,
    });

    expect(connections).toHaveBeenCalledWith(availableParallelism(), undefined, undefined);
    expect(packSize).toHaveBeenCalledWith(undefined, undefined);
  });

  it('prefers a stored connections override over the well-known value', async () => {
    const connections = jest.spyOn(yuccaWellKnown, 'getConnections').mockResolvedValue(7);
    jest.spyOn(yuccaWellKnown, 'getPackSizeMib').mockResolvedValue(undefined);
    const repository = new ConfigRepository(
      storedValue({ connections: 3 }) as never,
      { statePath: '/state' } as never,
      LoggingRepository.create(),
    );

    await expect(repository.getResticOptions({ siteCode: 'father', storageClusterCode: null })).resolves.toEqual({
      connections: 3,
      packSizeMib: undefined,
    });

    expect(connections).not.toHaveBeenCalled();
  });

  it('reports where the automatic connections come from', async () => {
    const connections = jest.spyOn(yuccaWellKnown, 'getConnections').mockResolvedValueOnce(7);
    const repository = new ConfigRepository(db as never, { statePath: '/state' } as never, LoggingRepository.create());
    const placement = { siteCode: null, storageClusterCode: null };

    await expect(repository.getAutomaticConnections(placement)).resolves.toEqual({
      connections: 7,
      source: ConnectionsSource.WellKnown,
    });

    connections.mockResolvedValueOnce(undefined);

    await expect(repository.getAutomaticConnections(placement)).resolves.toEqual({
      connections: availableParallelism(),
      source: ConnectionsSource.Cores,
    });
  });
});
