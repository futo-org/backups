import { ResticArchiveTag, ResticTagPrefix } from '../enum.js';

const SEGMENT = /^[\dA-F]{24}$/;
const PARTIAL_SEGMENT = /^[\dA-F]{24}\.partial$/;
const TIMELINE_HISTORY = /^[\dA-F]{8}\.history$/;

export type WalFile = { name: string; size: number; mtimeMs: number };

export type WalShipState = {
  lastSegment?: string;
  histories: string[];
  partial?: WalFile;
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

const baseStopLsn = (snapshot: WalArchiveSnapshot) => getTagValue(snapshot.tags, ResticTagPrefix.ImmichWalBaseStop);

const isBaseUsableFor = (snapshot: WalArchiveSnapshot, target: WalRestoreTarget) => {
  const stop = baseStopLsn(snapshot);
  if (!stop) {
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

export const planWalRestore = <T extends WalArchiveSnapshot>(snapshots: T[], target: WalRestoreTarget) => {
  const base = snapshots
    .filter((snapshot) => hasTag(snapshot, ResticArchiveTag.ImmichBase) && isBaseUsableFor(snapshot, target))
    .toSorted((a, b) => compareLsn(baseStopLsn(b)!, baseStopLsn(a)!))[0];

  if (!base) {
    throw new Error('No completed base backup precedes the restore target');
  }

  const wal = snapshots
    .filter((snapshot) => hasTag(snapshot, ResticArchiveTag.ImmichWal) && snapshot.time >= base.time)
    .toSorted((a, b) => +a.time - +b.time);

  return { base, wal };
};
