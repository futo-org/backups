import type {
  ConnectionDto,
  RepositoryMetricsDto,
} from '@futo-org/backups-api-client';
import { describe, expect, it } from 'vitest';
import { getOnboardingProgress, isOnboardingComplete } from './onboarding';

const connection = (overrides: Partial<ConnectionDto> = {}): ConnectionDto => ({
  id: 'connection-1',
  type: 'immich',
  name: 'Immich',
  createdAt: '2026-10-01T10:00:00.000Z',
  lastSeenAt: null,
  repositoryCount: 0,
  sizeBytes: 0,
  objectCount: 0,
  billableBytes: 0,
  ...overrides,
});

const repository = (metrics: Partial<RepositoryMetricsDto> = {}) => ({
  metrics: { sizeBytes: 0, ...metrics },
});

describe('getOnboardingProgress', () => {
  it('starts from nothing for a brand new account', () => {
    expect(getOnboardingProgress([], [])).toEqual({
      connected: false,
      connectionName: undefined,
      connectionType: undefined,
      firstBackup: 'waiting',
    });
  });

  it('does not count the default connection created at sign-up', () => {
    expect(getOnboardingProgress([connection()], []).connected).toBe(false);
  });

  it('counts a connection an app has used', () => {
    expect(
      getOnboardingProgress(
        [connection({ name: 'nas', lastSeenAt: '2026-10-02T10:00:00.000Z' })],
        [],
      ),
    ).toEqual({
      connected: true,
      connectionName: 'nas',
      connectionType: 'immich',
      firstBackup: 'waiting',
    });
  });

  it('names the most recently seen connection', () => {
    const progress = getOnboardingProgress(
      [
        connection({
          id: 'a',
          name: 'old',
          lastSeenAt: '2026-10-02T10:00:00.000Z',
        }),
        connection({
          id: 'b',
          name: 'new',
          lastSeenAt: '2026-10-05T10:00:00.000Z',
        }),
        connection({ id: 'c', name: 'unseen' }),
      ],
      [],
    );

    expect(progress.connectionName).toBe('new');
  });

  it('reports the type of a standalone connection', () => {
    const progress = getOnboardingProgress(
      [
        connection(),
        connection({
          id: 'standalone',
          type: 'standalone',
          name: 'homelab',
          lastSeenAt: '2026-10-02T10:00:00.000Z',
        }),
      ],
      [],
    );

    expect(progress).toMatchObject({
      connected: true,
      connectionName: 'homelab',
      connectionType: 'standalone',
    });
  });

  it('counts an existing backup as connected even without a seen connection', () => {
    expect(
      getOnboardingProgress([connection()], [repository()]).connected,
    ).toBe(true);
  });

  it('waits while the backup has not started', () => {
    expect(getOnboardingProgress([], [repository()]).firstBackup).toBe(
      'waiting',
    );
  });

  it('reports a running first backup with its start time', () => {
    const progress = getOnboardingProgress(
      [],
      [
        repository({
          lastStarted: '2026-10-29T10:00:00.000Z',
          lastBackupStatus: 'incomplete',
        }),
      ],
    );

    expect(progress).toMatchObject({
      firstBackup: 'running',
      startedAt: '2026-10-29T10:00:00.000Z',
    });
  });

  it.each(['complete', 'warn', 'failed', 'cancelled'] as const)(
    'finishes once a backup has ended as %s',
    (status) => {
      const progress = getOnboardingProgress(
        [],
        [
          repository({
            lastBackup: '2026-10-29T10:00:00.000Z',
            lastBackupStatus: status,
          }),
        ],
      );

      expect(progress.firstBackup).toBe('complete');
    },
  );

  it('stays finished while a later backup runs', () => {
    const progress = getOnboardingProgress(
      [],
      [
        repository({
          lastBackup: '2026-10-28T10:00:00.000Z',
          lastStarted: '2026-10-29T10:00:00.000Z',
          lastBackupStatus: 'incomplete',
        }),
      ],
    );

    expect(progress.firstBackup).toBe('complete');
  });
});

describe('isOnboardingComplete', () => {
  it('is false until a backup has finished', () => {
    expect(isOnboardingComplete([])).toBe(false);
    expect(
      isOnboardingComplete([
        repository({
          lastBackupStatus: 'incomplete',
          lastStarted: '2026-10-29T10:00:00.000Z',
        }),
      ]),
    ).toBe(false);
  });

  it('is true once any backup has finished', () => {
    expect(
      isOnboardingComplete([
        repository({
          lastBackup: '2026-10-29T10:00:00.000Z',
          lastBackupStatus: 'complete',
        }),
      ]),
    ).toBe(true);
  });
});
