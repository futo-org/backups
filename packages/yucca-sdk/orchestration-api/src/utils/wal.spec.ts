import { ResticArchiveTag, ResticTagPrefix } from '../enum.js';
import {
  compareLsn,
  isWalArchiveSnapshot,
  parseLsn,
  planWalRestore,
  selectWalFilesToPrune,
  selectWalFilesToShip,
  type WalArchiveSnapshot,
} from './wal.js';

const SEGMENT_1 = '000000010000000000000001';
const SEGMENT_2 = '000000010000000000000002';
const SEGMENT_3 = '000000010000000000000003';

const file = (name: string, size = 16, mtimeMs = 1) => ({ name, size, mtimeMs });

const base = (id: string, time: string, stop?: string, end = time): WalArchiveSnapshot => ({
  id,
  time: new Date(time),
  paths: ['/immich-base.tar'],
  tags: [ResticArchiveTag.ImmichBase, ...(stop ? [`${ResticTagPrefix.ImmichWalBaseStop}=${stop}`] : [])],
  summary: { backup_end: new Date(end) },
});

const wal = (id: string, time: string): WalArchiveSnapshot => ({
  id,
  time: new Date(time),
  paths: [`/wal/receive/${SEGMENT_1}`],
  tags: [ResticArchiveTag.ImmichWal],
});

describe(parseLsn.name, () => {
  it('combines both halves of the LSN', () => {
    expect(parseLsn('16/B374D848')).toBe(0x16_b3_74_d8_48n);
  });

  it('rejects garbage', () => {
    expect(() => parseLsn('nope')).toThrow('Invalid LSN');
  });
});

describe(compareLsn.name, () => {
  it('compares numerically rather than lexically', () => {
    expect(compareLsn('0/9000000', '0/10000000')).toBe(-1);
    expect(compareLsn('1/0', '0/FFFFFFFF')).toBe(1);
    expect(compareLsn('0/16B3748', '0/16b3748')).toBe(0);
  });
});

describe(selectWalFilesToShip.name, () => {
  it('ships completed segments and timeline histories that have not been shipped', () => {
    const files = [
      file(SEGMENT_3),
      file(SEGMENT_1),
      file(SEGMENT_2),
      file('00000002.history'),
      file('00000001.history'),
      file('state.tmp'),
    ];

    expect(selectWalFilesToShip(files, { lastSegment: SEGMENT_1, histories: ['00000001.history'] }, false)).toEqual({
      segments: [SEGMENT_2, SEGMENT_3],
      histories: ['00000002.history'],
      partial: undefined,
    });
  });

  it('ships the partial segment only when it changed since the last ship', () => {
    const partial = file(`${SEGMENT_2}.partial`, 16, 5);
    const state = { lastSegment: SEGMENT_1, histories: [], partial };

    expect(selectWalFilesToShip([partial], state, true).partial).toBeUndefined();
    expect(selectWalFilesToShip([{ ...partial, mtimeMs: 6 }], state, true).partial).toEqual({ ...partial, mtimeMs: 6 });
    expect(selectWalFilesToShip([{ ...partial, mtimeMs: 6 }], state, false).partial).toBeUndefined();
  });
});

describe(selectWalFilesToPrune.name, () => {
  it('keeps the newest shipped segment, unshipped segments and the partial', () => {
    const names = [SEGMENT_1, SEGMENT_2, SEGMENT_3, `${SEGMENT_3}.partial`, '00000001.history'];

    expect(selectWalFilesToPrune(names, SEGMENT_2)).toEqual([SEGMENT_1]);
  });

  it('prunes nothing before the first ship', () => {
    expect(selectWalFilesToPrune([SEGMENT_1], undefined)).toEqual([]);
  });
});

describe(planWalRestore.name, () => {
  const snapshots = [
    base('base-1', '2026-11-01T00:00:00Z', '0/2000100'),
    wal('wal-1', '2026-11-01T00:05:00Z'),
    base('base-incomplete', '2026-11-01T12:00:00Z'),
    base('base-2', '2026-11-02T00:00:00Z', '0/5000100', '2026-11-02T00:10:00Z'),
    wal('wal-2', '2026-11-02T00:20:00Z'),
    wal('wal-0', '2026-10-31T00:00:00Z'),
  ];

  it('picks the newest completed base at or before the target LSN and every WAL snapshot after it', () => {
    const { base, wal } = planWalRestore(snapshots, { lsn: '0/4000000' });

    expect(base.id).toBe('base-1');
    expect(wal.map(({ id }) => id)).toEqual(['wal-1', 'wal-2']);
  });

  it('uses the newest base for the latest state', () => {
    const { base, wal } = planWalRestore(snapshots, 'latest');

    expect(base.id).toBe('base-2');
    expect(wal.map(({ id }) => id)).toEqual(['wal-2']);
  });

  it('only accepts a base that finished before the target time', () => {
    expect(planWalRestore(snapshots, { time: new Date('2026-11-02T00:05:00Z') }).base.id).toBe('base-1');
    expect(planWalRestore(snapshots, { time: new Date('2026-11-02T00:15:00Z') }).base.id).toBe('base-2');
  });

  it('fails when no base precedes the target', () => {
    expect(() => planWalRestore(snapshots, { lsn: '0/1000000' })).toThrow('No completed base backup');
  });
});

describe(isWalArchiveSnapshot.name, () => {
  it('tells archive snapshots apart from library snapshots', () => {
    expect(isWalArchiveSnapshot({ tags: [ResticArchiveTag.ImmichWal] })).toBe(true);
    expect(isWalArchiveSnapshot({ tags: [ResticArchiveTag.ImmichBase] })).toBe(true);
    expect(isWalArchiveSnapshot({ tags: [`${ResticTagPrefix.ImmichWalLsn}=0/1`] })).toBe(false);
    expect(isWalArchiveSnapshot({})).toBe(false);
  });
});
