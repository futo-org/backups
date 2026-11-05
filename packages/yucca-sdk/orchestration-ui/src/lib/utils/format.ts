import { Duration } from 'luxon';
import { gt, msg } from 'svelte-i18n-lingui';

const MAX_DURATION_UNITS = 3;

const SECOND = 1000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

const durationUnits = [
  {
    unit: 'years',
    ms: 365 * DAY,
    narrow: (count: number) =>
      gt({
        message: '{count}y',
        comment: 'Abbreviated number of years',
        values: { count },
      }),
  },
  {
    unit: 'months',
    ms: 30 * DAY,
    narrow: (count: number) =>
      gt({
        message: '{count}M',
        comment: 'Abbreviated number of months',
        values: { count },
      }),
  },
  {
    unit: 'weeks',
    ms: 7 * DAY,
    narrow: (count: number) =>
      gt({
        message: '{count}w',
        comment: 'Abbreviated number of weeks',
        values: { count },
      }),
  },
  {
    unit: 'days',
    ms: DAY,
    narrow: (count: number) =>
      gt({
        message: '{count}d',
        comment: 'Abbreviated number of days',
        values: { count },
      }),
  },
  {
    unit: 'hours',
    ms: HOUR,
    narrow: (count: number) =>
      gt({
        message: '{count}h',
        comment: 'Abbreviated number of hours',
        values: { count },
      }),
  },
  {
    unit: 'minutes',
    ms: MINUTE,
    narrow: (count: number) =>
      gt({
        message: '{count}m',
        comment: 'Abbreviated number of minutes',
        values: { count },
      }),
  },
  {
    unit: 'seconds',
    ms: SECOND,
    narrow: (count: number) =>
      gt({
        message: '{count}s',
        comment: 'Abbreviated number of seconds',
        values: { count },
      }),
  },
] as const;

const splitIntoUnits = (ms: number) => {
  let rest = ms;
  return durationUnits.map((durationUnit) => {
    const count = Math.floor(rest / durationUnit.ms);
    rest -= count * durationUnit.ms;
    return { ...durationUnit, count };
  });
};

export const formatDuration = (
  ms: number,
  unitDisplay: 'narrow' | 'long' = 'narrow',
) => {
  const seconds = Math.round(ms / SECOND);
  if (seconds < 1) {
    return '<1s';
  }

  const largestUnits = splitIntoUnits(seconds * SECOND)
    .filter(({ count }) => count > 0)
    .slice(0, MAX_DURATION_UNITS);

  if (unitDisplay === 'long') {
    return Duration.fromObject(
      Object.fromEntries(largestUnits.map(({ unit, count }) => [unit, count])),
    ).toHuman({ unitDisplay });
  }

  return largestUnits.map(({ narrow, count }) => narrow(count)).join(', ');
};

const IMMICH_FOLDER_LABELS: Record<string, string> = {
  upload: msg`Photos and videos`,
  profile: msg`Photos and videos`,
  library: msg`Photos and videos`,
  backups: msg`Database backups`,
  thumbs: msg`Thumbnails and previews`,
  'encoded-video': msg`Encoded videos`,
};

export const humanizeBackupPath = (path: string): string => {
  if (path.includes('yucca')) {
    return gt`Backup configuration`;
  }

  const basename = path.replace(/\/+$/, '').split('/').pop() ?? path;
  const label = IMMICH_FOLDER_LABELS[basename];
  return label ? gt(label) : basename;
};
