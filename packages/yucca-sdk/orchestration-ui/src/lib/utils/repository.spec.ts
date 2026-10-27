import type {
  InspectedLocalRepositoryDto,
  SnapshotDto,
} from '$lib/fetch-client';
import {
  isRestorable,
  latestSnapshot,
  sortRestoreCandidates,
} from '$lib/utils/repository';
import { describe, expect, it } from 'vitest';

const snapshot = (id: string, time: string): SnapshotDto => ({
  id,
  time,
  paths: ['/data'],
});

const repository = (
  id: string,
  name: string,
  snapshots?: SnapshotDto[],
): InspectedLocalRepositoryDto => ({
  id,
  name,
  worm: false,
  siteCode: null,
  storageClusterCode: null,
  metrics: { sizeBytes: 0 },
  snapshots,
});

describe('latestSnapshot', () => {
  it('picks the newest snapshot regardless of order', () => {
    const snapshots = [
      snapshot('old', '2026-10-01T00:00:00Z'),
      snapshot('new', '2026-10-25T00:00:00Z'),
      snapshot('mid', '2026-10-10T00:00:00Z'),
    ];

    expect(latestSnapshot(snapshots)?.id).toBe('new');
  });

  it('returns undefined without snapshots', () => {
    expect(latestSnapshot([])).toBeUndefined();
    expect(latestSnapshot(undefined)).toBeUndefined();
  });
});

describe('isRestorable', () => {
  it('only accepts repositories with snapshots', () => {
    expect(
      isRestorable(
        repository('a', 'Immich', [snapshot('s', '2026-10-25T00:00:00Z')]),
      ),
    ).toBe(true);
    expect(isRestorable(repository('b', 'Immich', []))).toBe(false);
    expect(isRestorable(repository('c', 'Immich'))).toBe(false);
  });
});

describe('sortRestoreCandidates', () => {
  it('lists restorable repositories first, then inaccessible, then empty ones', () => {
    const sorted = sortRestoreCandidates([
      repository('empty', 'Immich', []),
      repository('inaccessible', 'Immich'),
      repository('full', 'Immich', [snapshot('s', '2026-10-25T00:00:00Z')]),
    ]);

    expect(sorted.map(({ id }) => id)).toEqual([
      'full',
      'inaccessible',
      'empty',
    ]);
  });

  it('prefers Immich repositories, then the most recent backup', () => {
    const sorted = sortRestoreCandidates([
      repository('other', 'Unknown', [snapshot('s', '2026-10-26T00:00:00Z')]),
      repository('older', 'Immich', [snapshot('s', '2026-10-01T00:00:00Z')]),
      repository('newer', 'Immich', [
        snapshot('s1', '2026-10-25T00:00:00Z'),
        snapshot('s2', '2026-10-02T00:00:00Z'),
      ]),
    ]);

    expect(sorted.map(({ id }) => id)).toEqual(['newer', 'older', 'other']);
  });
});
