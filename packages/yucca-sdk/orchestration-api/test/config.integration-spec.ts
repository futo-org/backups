import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { bootConfig, BootedConfig } from './testUtils.js';

const hex = (fill: string) => fill.repeat(64);

let statePath: string;
let booted: BootedConfig;

const rows = async () => {
  const all = await booted.db.selectFrom('futo_backups_config').selectAll().execute();
  return all.toSorted((a, b) => a.key.localeCompare(b.key));
};

const row = async (key: string) => {
  const all = await rows();
  return all.filter((candidate) => candidate.key === key);
};

beforeEach(async () => {
  statePath = await mkdtemp(join(tmpdir(), 'yucca-config-'));
  booted = await bootConfig(statePath);
});

afterEach(async () => {
  await booted.close();
});

describe('Configuration upsert', () => {
  it('starts with an empty configuration table', async () => {
    await expect(rows()).resolves.toEqual([]);
  });

  it('inserts a single key and then updates it in place without touching its neighbours', async () => {
    await booted.config.bootstrap();
    const secret = await booted.config.getSessionSecret();
    const before = await rows();

    await booted.config.importEncryptionKey(hex('a'));

    await expect(booted.config.getMasterEncryptionKey()).resolves.toEqual(hex('a'));
    await expect(booted.config.getSessionSecret()).resolves.toEqual(secret);
    const after = await rows();
    expect(after).toHaveLength(before.length);
    expect(after.filter((candidate) => candidate.key !== 'encryption-key')).toEqual(
      before.filter((candidate) => candidate.key !== 'encryption-key'),
    );
  });

  it('keeps one row per key across repeated writes of the same key', async () => {
    await booted.config.importEncryptionKey(hex('a'));
    await booted.config.importEncryptionKey(hex('b'));
    await booted.config.importEncryptionKey(hex('c'));

    await expect(row('encryption-key')).resolves.toEqual([{ key: 'encryption-key', value: { key: hex('c') } }]);
  });

  it.each([
    ['single and double quotes', `it's "quoted"`],
    ['sql-looking text', `'); DROP TABLE config; --`],
    ['unicode outside the basic plane', 'clé 密钥 🔑 ключ'],
    ['a very long string', 'x'.repeat(100_000)],
  ])('round trips %s through insert and update', async (_, value) => {
    await booted.config.importEncryptionKey(hex('0'));
    await booted.config.importEncryptionKey(value);

    await expect(booted.config.getMasterEncryptionKey()).resolves.toEqual(value);
    await expect(row('encryption-key')).resolves.toEqual([{ key: 'encryption-key', value: { key: value } }]);
  });

  it('leaves every key at its own last written value when writers interleave', async () => {
    await booted.config.bootstrap();
    await booted.config.setThrottle({ bytesPerSec: 1000, quietHours: '01:00-02:00' });
    await booted.config.enableTelemetry();
    await booted.config.importEncryptionKey(hex('a'));
    await booted.config.confirmKeyOnboarded();
    await booted.config.setThrottle({ bytesPerSec: 2000, quietHours: '03:00-04:00' });
    await booted.config.skipExtraConfig();
    await booted.config.importEncryptionKey(hex('b'));
    await booted.config.setThrottle({ bytesPerSec: 3000 });

    await expect(booted.config.getMasterEncryptionKey()).resolves.toEqual(hex('b'));
    await expect(booted.config.getThrottle()).resolves.toEqual({ bytesPerSec: 3000, quietHours: undefined });
    await expect(booted.config.hasTelemetry()).resolves.toBe(true);
    await expect(booted.config.hasOnboardedKey()).resolves.toBe(true);
    await expect(booted.config.hasSkippedExtraConfig()).resolves.toBe(true);
    await expect(booted.config.hasSessionSecret()).resolves.toBe(true);
    const keys = await rows();
    expect(keys.map((candidate) => candidate.key)).toEqual([
      'encryption-key',
      'onboarded-key',
      'session-secret',
      'skipped-onboarding-extra-config',
      'state-path',
      'telemetry',
      'throttle',
    ]);
  });

  it('reports flags as absent until their writer runs', async () => {
    await expect(booted.config.hasTelemetry()).resolves.toBe(false);
    await expect(booted.config.hasOnboardedKey()).resolves.toBe(false);
    await expect(booted.config.hasSkippedExtraConfig()).resolves.toBe(false);
    await expect(booted.config.hasEncryptionKey()).resolves.toBe(false);
    await expect(booted.config.hasSessionSecret()).resolves.toBe(false);
  });

  it('keeps the key and secret across a second bootstrap', async () => {
    await booted.config.bootstrap();
    const key = await booted.config.getMasterEncryptionKey();
    const secret = await booted.config.getSessionSecret();

    await booted.config.bootstrap();

    await expect(booted.config.getMasterEncryptionKey()).resolves.toEqual(key);
    await expect(booted.config.getSessionSecret()).resolves.toEqual(secret);
  });

  it('survives closing and reopening the database', async () => {
    await booted.config.bootstrap();
    await booted.config.importEncryptionKey(hex('a'));
    await booted.config.setThrottle({ bytesPerSec: 1000, quietHours: '01:00-02:00' });
    await booted.config.setThrottle({ bytesPerSec: 2000, quietHours: '03:00-04:00' });
    await booted.config.enableTelemetry();
    const secret = await booted.config.getSessionSecret();
    const before = await rows();
    await booted.close();

    booted = await bootConfig(statePath);

    await expect(rows()).resolves.toEqual(before);
    await expect(booted.config.getMasterEncryptionKey()).resolves.toEqual(hex('a'));
    await expect(booted.config.getSessionSecret()).resolves.toEqual(secret);
    await expect(booted.config.getThrottle()).resolves.toEqual({ bytesPerSec: 2000, quietHours: '03:00-04:00' });
    await expect(booted.config.hasTelemetry()).resolves.toBe(true);
  });
});

describe('Support mode', () => {
  it('is off until configured', async () => {
    await expect(booted.config.getSupportMode()).resolves.toEqual({
      remainingRuns: 0,
      streamToFuto: false,
      includePaths: false,
    });
    await expect(booted.config.consumeSupportModeRun()).resolves.toBeUndefined();
  });

  it('counts down one run at a time and then switches itself off', async () => {
    await booted.config.setSupportMode({ remainingRuns: 2, streamToFuto: true, includePaths: false });

    await expect(booted.config.consumeSupportModeRun()).resolves.toMatchObject({ remainingRuns: 2 });
    await expect(booted.config.consumeSupportModeRun()).resolves.toMatchObject({ remainingRuns: 1 });
    await expect(booted.config.consumeSupportModeRun()).resolves.toBeUndefined();
    await expect(booted.config.getSupportMode()).resolves.toEqual({
      remainingRuns: 0,
      streamToFuto: true,
      includePaths: false,
    });
  });
});
