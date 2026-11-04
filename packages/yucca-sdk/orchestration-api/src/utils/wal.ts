import { ResticArchiveTag, ResticTagPrefix } from '../enum.js';

const SEGMENT = /^[\dA-F]{24}$/;
const PARTIAL_SEGMENT = /^[\dA-F]{24}\.partial$/;
const TIMELINE_HISTORY = /^[\dA-F]{8}\.history$/;

export type WalFile = { name: string; size: number; mtimeMs: number };

export type WalShipState = {
  lastSegment?: string;
  histories: string[];
  partial?: WalFile;
  baseRequiredSince?: number;
};

export type WalShipSelection = {
  segments: string[];
  histories: string[];
  partial?: WalFile;
};

export type WalArchiveSnapshot = {
  id: string;
  time: Date;
  paths: string[];
  tags?: string[];
  summary?: { backup_end: Date };
};

export type WalRestoreTarget = { lsn: string } | { time: Date } | 'latest';

export const parseLsn = (lsn: string): bigint => {
  const match = /^([\dA-F]{1,8})\/([\dA-F]{1,8})$/i.exec(lsn.trim());
  if (!match) {
    throw new Error(`Invalid LSN: ${lsn}`);
  }

  return (BigInt(`0x${match[1]}`) << 32n) | BigInt(`0x${match[2]}`);
};

export const compareLsn = (a: string, b: string) => {
  const difference = parseLsn(a) - parseLsn(b);
  return difference === 0n ? 0 : difference < 0n ? -1 : 1;
};

export const isWalSegment = (name: string) => SEGMENT.test(name);
export const isPartialWalSegment = (name: string) => PARTIAL_SEGMENT.test(name);
export const isTimelineHistory = (name: string) => TIMELINE_HISTORY.test(name);

const WAL_SEGMENT_SIZE = 16n * 1024n * 1024n;
const SEGMENTS_PER_XLOG_ID = 0x1_00_00_00_00n / WAL_SEGMENT_SIZE;

export const SUPPORTED_WAL_SEGMENT_SIZE = '16MB';

const hex8 = (value: bigint) => value.toString(16).toUpperCase().padStart(8, '0');

const formatSegment = (timeline: string, index: bigint) =>
  `${timeline}${hex8(index / SEGMENTS_PER_XLOG_ID)}${hex8(index % SEGMENTS_PER_XLOG_ID)}`;

export const nextSegment = (name: string) =>
  formatSegment(
    name.slice(0, 8),
    BigInt(`0x${name.slice(8, 16)}`) * SEGMENTS_PER_XLOG_ID + BigInt(`0x${name.slice(16, 24)}`) + 1n,
  );

export const segmentContainingLsn = (timeline: string, lsn: string) =>
  formatSegment(timeline, (parseLsn(lsn) - 1n) / WAL_SEGMENT_SIZE);

export const splitContiguousSegments = (segments: string[]) => {
  const runs: string[][] = [];
  for (const segment of segments.toSorted()) {
    const run = runs.at(-1);
    if (run && nextSegment(run.at(-1)!) === segment) {
      run.push(segment);
    } else {
      runs.push([segment]);
    }
  }

  return runs;
};

export const getTagValue = (tags: string[] | undefined, prefix: ResticTagPrefix) =>
  tags?.find((tag) => tag.startsWith(`${prefix}=`))?.slice(prefix.length + 1);

const hasTag = (snapshot: { tags?: string[] }, tag: ResticArchiveTag) => snapshot.tags?.includes(tag) ?? false;

export const isWalArchiveSnapshot = (snapshot: { tags?: string[] }) =>
  hasTag(snapshot, ResticArchiveTag.ImmichWal) || hasTag(snapshot, ResticArchiveTag.ImmichBase);

export const selectWalFilesToShip = (files: WalFile[], state: WalShipState, shipPartial: boolean): WalShipSelection => {
  const segments = files
    .map(({ name }) => name)
    .filter((name) => isWalSegment(name) && (!state.lastSegment || name > state.lastSegment))
    .toSorted();
  const histories = files
    .map(({ name }) => name)
    .filter((name) => isTimelineHistory(name) && !state.histories.includes(name))
    .toSorted();

  const partial = shipPartial ? files.find(({ name }) => isPartialWalSegment(name)) : undefined;
  const partialChanged =
    partial &&
    (partial.name !== state.partial?.name ||
      partial.size !== state.partial.size ||
      partial.mtimeMs !== state.partial.mtimeMs);

  return { segments, histories, partial: partialChanged ? partial : undefined };
};

export const selectWalFilesToPrune = (names: string[], lastShippedSegment: string | undefined) => {
  if (!lastShippedSegment) {
    return [];
  }

  // pg_receivewal on PG14 resumes from the newest segment in its directory and otherwise from the server's current
  // position, so the newest shipped segment stays behind to keep the stream gapless across restarts.
  return names.filter((name) => isWalSegment(name) && name < lastShippedSegment).toSorted();
};

const tagged = (snapshot: { tags?: string[] }, prefix: ResticTagPrefix) => getTagValue(snapshot.tags, prefix);

const baseStopLsn = (snapshot: WalArchiveSnapshot) => tagged(snapshot, ResticTagPrefix.ImmichWalBaseStop);

const isBaseUsableFor = (snapshot: WalArchiveSnapshot, target: WalRestoreTarget) => {
  const stop = baseStopLsn(snapshot);
  if (!stop || !tagged(snapshot, ResticTagPrefix.ImmichWalBaseStartSegment)) {
    return false;
  }

  if (target === 'latest') {
    return true;
  }

  if ('lsn' in target) {
    return compareLsn(stop, target.lsn) <= 0;
  }

  return snapshot.summary !== undefined && snapshot.summary.backup_end <= target.time;
};

type WalCoverage<T> = { snapshot: T; first?: string; last?: string; partial?: string };

const toCoverage = <T extends WalArchiveSnapshot>(snapshot: T): WalCoverage<T> => ({
  snapshot,
  first: tagged(snapshot, ResticTagPrefix.ImmichWalFirstSegment),
  last: tagged(snapshot, ResticTagPrefix.ImmichWalLastSegment),
  partial: tagged(snapshot, ResticTagPrefix.ImmichWalPartialSegment),
});

const followContinuousWal = <T extends WalArchiveSnapshot>(archives: WalCoverage<T>[], start: string) => {
  const selected: T[] = [];
  let next = start;

  const complete = archives
    .filter((archive): archive is WalCoverage<T> & { first: string; last: string } => !!archive.first && !!archive.last)
    .toSorted((a, b) => a.first.localeCompare(b.first));
  for (const { snapshot, first, last } of complete) {
    if (last < next) {
      continue;
    }
    if (first > next) {
      break;
    }
    selected.push(snapshot);
    next = nextSegment(last);
  }

  const partial = archives
    .filter((archive) => archive.partial === next)
    .toSorted((a, b) => +b.snapshot.time - +a.snapshot.time)[0];
  if (partial) {
    selected.push(partial.snapshot);
  }

  const gap = archives.some(
    ({ last, partial: partialSegment }) =>
      (last !== undefined && last >= next) || (partialSegment !== undefined && partialSegment > next),
  );

  return { selected, next, partial: partial !== undefined, gap };
};

export const planWalRestore = <T extends WalArchiveSnapshot>(snapshots: T[], target: WalRestoreTarget) => {
  const base = snapshots
    .filter((snapshot) => hasTag(snapshot, ResticArchiveTag.ImmichBase) && isBaseUsableFor(snapshot, target))
    .toSorted((a, b) => compareLsn(baseStopLsn(b)!, baseStopLsn(a)!))[0];

  if (!base) {
    throw new Error('No completed base backup precedes the restore target');
  }

  const start = tagged(base, ResticTagPrefix.ImmichWalBaseStartSegment)!;
  const timeline = start.slice(0, 8);
  const archives = snapshots
    .filter((snapshot) => hasTag(snapshot, ResticArchiveTag.ImmichWal))
    .map((snapshot) => toCoverage(snapshot))
    .filter(({ first, partial }) => (first ?? partial)?.startsWith(timeline));

  const { selected, next, partial, gap } = followContinuousWal(archives, start);

  if (target !== 'latest' && 'lsn' in target) {
    const end = segmentContainingLsn(timeline, target.lsn);
    if (end > next || (end === next && !partial)) {
      throw new Error(`Archived WAL is missing from segment ${next}, but the target needs it up to ${end}`);
    }
  } else if (gap) {
    const lastReachable = selected.at(-1)?.time ?? base.time;
    if (target === 'latest' || target.time > lastReachable) {
      throw new Error(
        `Archived WAL has a gap at segment ${next}, so the target cannot be reached from the base backup`,
      );
    }
  }

  return { base, wal: selected.toSorted((a, b) => +a.time - +b.time) };
};
