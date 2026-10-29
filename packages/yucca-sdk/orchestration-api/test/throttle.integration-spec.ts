import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { bootConfig, BootedConfig } from './testUtils.js';

let statePath: string;
let booted: BootedConfig;

beforeEach(async () => {
  statePath = await mkdtemp(join(tmpdir(), 'yucca-throttle-'));
  booted = await bootConfig(statePath);
});

afterEach(async () => {
  await booted.close();
});

describe('Throttle configuration', () => {
  it('reports no throttle until one is stored', async () => {
    await expect(booted.config.getThrottle()).resolves.toBeUndefined();
  });

  it('stores a rate and a quiet hours window together', async () => {
    await booted.config.setThrottle({ bytesPerSec: 5_000_000, quietHours: '22:00-06:00' });

    await expect(booted.config.getThrottle()).resolves.toEqual({
      bytesPerSec: 5_000_000,
      quietHours: '22:00-06:00',
    });
  });

  it('updates both values when they change together', async () => {
    await booted.config.setThrottle({ bytesPerSec: 5_000_000, quietHours: '22:00-06:00' });
    await booted.config.setThrottle({ bytesPerSec: 1_000_000, quietHours: '09:00-17:00' });

    await expect(booted.config.getThrottle()).resolves.toEqual({
      bytesPerSec: 1_000_000,
      quietHours: '09:00-17:00',
    });
  });

  it('stores an unthrottled rate of zero as zero rather than as no throttle', async () => {
    await booted.config.setThrottle({ bytesPerSec: 0 });

    await expect(booted.config.getThrottle()).resolves.toEqual({ bytesPerSec: 0, quietHours: undefined });
  });

  it('clears the window without clearing the rate', async () => {
    await booted.config.setThrottle({ bytesPerSec: 5_000_000, quietHours: '22:00-06:00' });
    await booted.config.setThrottle({ bytesPerSec: 5_000_000 });

    await expect(booted.config.getThrottle()).resolves.toEqual({ bytesPerSec: 5_000_000, quietHours: undefined });
  });

  it('leaves other configuration untouched', async () => {
    await booted.config.bootstrap();
    const key = await booted.config.getMasterEncryptionKey();

    await booted.config.setThrottle({ bytesPerSec: 2_000_000, quietHours: '01:00-02:00' });

    await expect(booted.config.getMasterEncryptionKey()).resolves.toEqual(key);
  });

  it('survives a restart of the orchestrator', async () => {
    await booted.config.setThrottle({ bytesPerSec: 750_000, quietHours: '23:30-05:45' });
    await booted.close();

    booted = await bootConfig(statePath);

    await expect(booted.config.getThrottle()).resolves.toEqual({
      bytesPerSec: 750_000,
      quietHours: '23:30-05:45',
    });
  });
});
