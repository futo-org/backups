import {
  futoBackupsUpdateConfig,
  type ConfigResponseDto,
} from '$lib/fetch-client';
import { queryClient } from '$lib/query-client';
import {
  configKeys,
  toBandwidthDto,
  toBandwidthForm,
  toConnectionsOverride,
  useUpdateConfig,
} from '$lib/services/config.service';
import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('$lib/fetch-client');

const connections: ConfigResponseDto['connections'] = {
  override: null,
  automatic: 8,
  effective: 8,
  source: 'well-known',
  min: 1,
  max: 128,
};

describe('toBandwidthForm', () => {
  it('reads the limit and quiet hours from the saved config', () => {
    expect(
      toBandwidthForm({ bytesPerSec: 5_000_000, quietHours: '23:00-07:00' }),
    ).toEqual({
      mbps: 40,
      quiet: true,
      quietStart: '23:00',
      quietEnd: '07:00',
    });
  });

  it('falls back to the default quiet hours when none are saved', () => {
    expect(toBandwidthForm({ bytesPerSec: 0 })).toEqual({
      mbps: undefined,
      quiet: false,
      quietStart: '22:00',
      quietEnd: '06:00',
    });
  });
});

describe('toBandwidthDto', () => {
  it('converts megabits per second to bytes per second with quiet hours', () => {
    expect(
      toBandwidthDto({
        mbps: 4,
        quiet: true,
        quietStart: '22:00',
        quietEnd: '06:00',
      }),
    ).toEqual({ bytesPerSec: 500_000, quietHours: '22:00-06:00' });
  });

  it('clears quiet hours when they are switched off', () => {
    expect(
      toBandwidthDto({
        mbps: 16,
        quiet: false,
        quietStart: '22:00',
        quietEnd: '06:00',
      }),
    ).toEqual({ bytesPerSec: 2_000_000, quietHours: undefined });
  });

  it('disables the limit and drops quiet hours when set to no limit', () => {
    expect(
      toBandwidthDto({
        mbps: 0,
        quiet: true,
        quietStart: '22:00',
        quietEnd: '06:00',
      }),
    ).toEqual({ bytesPerSec: 0, quietHours: undefined });
  });

  it('treats an empty speed as no limit', () => {
    expect(
      toBandwidthDto({
        mbps: undefined,
        quiet: true,
        quietStart: '22:00',
        quietEnd: '06:00',
      }),
    ).toEqual({ bytesPerSec: 0, quietHours: undefined });
  });

  it('round trips a saved config', () => {
    const bandwidth = { bytesPerSec: 10_000_000, quietHours: '01:00-05:00' };

    expect(toBandwidthDto(toBandwidthForm(bandwidth))).toEqual(bandwidth);
  });
});

describe('toConnectionsOverride', () => {
  it('clears the override when the field is empty', () => {
    expect(toConnectionsOverride(undefined, connections)).toBeNull();
    expect(toConnectionsOverride(Number.NaN, connections)).toBeNull();
  });

  it('keeps a whole number within range', () => {
    expect(toConnectionsOverride(12, connections)).toBe(12);
  });

  it('rounds and clamps to the allowed range', () => {
    expect(toConnectionsOverride(2.4, connections)).toBe(2);
    expect(toConnectionsOverride(0, connections)).toBe(1);
    expect(toConnectionsOverride(500, connections)).toBe(128);
  });
});

describe('useUpdateConfig', () => {
  beforeEach(() => {
    queryClient.clear();
    vi.clearAllMocks();
  });

  it('sends the bandwidth through the SDK and caches the saved config', async () => {
    const saved: ConfigResponseDto = {
      bandwidth: { bytesPerSec: 1_000_000, quietHours: '22:00-06:00' },
      connections,
    };
    vi.mocked(futoBackupsUpdateConfig).mockResolvedValue(saved);

    useUpdateConfig().mutate({
      bandwidth: toBandwidthDto({
        mbps: 8,
        quiet: true,
        quietStart: '22:00',
        quietEnd: '06:00',
      }),
    });

    await vi.waitFor(() =>
      expect(queryClient.getQueryData(configKeys.all)).toEqual(saved),
    );
    expect(futoBackupsUpdateConfig).toHaveBeenCalledWith({
      bandwidth: saved.bandwidth,
    });
  });

  it('sends a zero limit without quiet hours to disable throttling', async () => {
    const saved: ConfigResponseDto = {
      bandwidth: { bytesPerSec: 0 },
      connections,
    };
    vi.mocked(futoBackupsUpdateConfig).mockResolvedValue(saved);

    useUpdateConfig().mutate({
      bandwidth: toBandwidthDto({
        mbps: 0,
        quiet: true,
        quietStart: '22:00',
        quietEnd: '06:00',
      }),
    });

    await vi.waitFor(() =>
      expect(queryClient.getQueryData(configKeys.all)).toEqual(saved),
    );
    expect(futoBackupsUpdateConfig).toHaveBeenCalledWith({
      bandwidth: { bytesPerSec: 0, quietHours: undefined },
    });
  });

  it('sends a connections override alongside the bandwidth', async () => {
    const saved: ConfigResponseDto = {
      bandwidth: { bytesPerSec: 0 },
      connections: {
        ...connections,
        override: 4,
        effective: 4,
        source: 'override',
      },
    };
    vi.mocked(futoBackupsUpdateConfig).mockResolvedValue(saved);

    useUpdateConfig().mutate({
      bandwidth: { bytesPerSec: 0 },
      connections: toConnectionsOverride(4, connections),
    });

    await vi.waitFor(() =>
      expect(queryClient.getQueryData(configKeys.all)).toEqual(saved),
    );
    expect(futoBackupsUpdateConfig).toHaveBeenCalledWith({
      bandwidth: { bytesPerSec: 0 },
      connections: 4,
    });
  });
});
