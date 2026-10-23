import { formatVersions } from './versions.js';

describe(formatVersions.name, () => {
  it('reports every observed version with its source and last seen time', () => {
    const result = formatVersions({
      versions: [
        {
          component: 'orchestration-api (client)',
          version: '0.40.1',
          source: 'logs',
          lastSeen: '2026-10-01T00:00:00Z',
        },
        { component: 'orchestration-api (client)', version: '1.2.1', source: 'logs', lastSeen: '2026-10-22T00:00:00Z' },
        { component: 'michael (service)', version: '1.2.1', source: 'metrics' },
      ],
      unavailableSources: [],
    });

    expect(result).toContain('0.40.1 (logs; last seen 2026-10-01T00:00:00Z)');
    expect(result).toContain('1.2.1 (logs; last seen 2026-10-22T00:00:00Z)');
    expect(result).toContain('michael (service): 1.2.1 (metrics)');
  });

  it('does not confuse service versions with the client version', () => {
    expect(
      formatVersions({
        versions: [{ component: 'michael (service)', version: '1.2.1', source: 'metrics' }],
        unavailableSources: [],
      }),
    ).toContain('Client version: unknown');
  });

  it('distinguishes absent telemetry from unavailable telemetry', () => {
    expect(formatVersions({ versions: [], unavailableSources: [] })).toContain('no version telemetry found');
    expect(formatVersions({ versions: [], unavailableSources: ['logs'] })).toContain('lookup unavailable');
    expect(formatVersions(null)).toContain('lookup unavailable');
  });

  it('reports unknown service versions when only client versions were observed', () => {
    const result = formatVersions({
      versions: [{ component: 'orchestration-api (client)', version: '1.2.1', source: 'logs' }],
      unavailableSources: [],
    });

    expect(result).toContain('Service versions: unknown — no service versions were observed.');
    expect(result).not.toContain('lookup unavailable');
  });

  it('keeps observed evidence when another source fails', () => {
    const result = formatVersions({
      versions: [{ component: 'orchestration-api (client)', version: '1.2.1', source: 'logs' }],
      unavailableSources: ['metrics'],
    });

    expect(result).toContain('1.2.1');
    expect(result).toContain('Unavailable telemetry: metrics');
    expect(result).toContain('Service versions: unknown — metrics lookup unavailable.');
  });
});
