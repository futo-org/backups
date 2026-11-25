import { validateCronExpression } from 'cron';
import cronstrue from 'cronstrue';
import type { ScheduleDefaultsDto } from '$lib/fetch-client';
import { DateTime } from 'luxon';
import { gt } from 'svelte-i18n-lingui';

const MINUTES_PER_HOUR = 60;

const expandMinutes = (field: string) => {
  const minutes = new Set<number>();

  for (const part of field.split(',')) {
    const [range = '', step] = part.split('/');
    const [from = Number.NaN, to] =
      range === '*' ? [0, MINUTES_PER_HOUR - 1] : range.split('-').map(Number);
    const last = Math.min(
      to ?? (step === undefined ? from : MINUTES_PER_HOUR - 1),
      MINUTES_PER_HOUR - 1,
    );
    const increment = Math.max(1, Number(step ?? 1) || 1);

    for (let minute = from; minute <= last; minute += increment) {
      minutes.add(minute);
    }
  }

  return minutes;
};

export const runsMoreThanHourly = (cron: string) => {
  const [minute = ''] = cron.trim().split(/\s+/);
  return expandMinutes(minute).size > 1;
};

export const schedulePresets = ['daily', 'weekly', 'monthly'] as const;

export type SchedulePreset = (typeof schedulePresets)[number];

export const toSchedulePreset = (cron: string) =>
  schedulePresets.find((preset) => cron === `@${preset}`);

export const isValidCron = (cron: string) => validateCronExpression(cron).valid;

export const resolveCron = (
  cron: string,
  defaults: Record<SchedulePreset, string> | undefined,
) => {
  const preset = toSchedulePreset(cron);
  return (preset && defaults?.[preset]) ?? cron;
};

export const withTimeZone = (text: string, tz: string | undefined) =>
  !tz || tz === DateTime.local().zoneName
    ? text
    : `${text} (${tz.replaceAll('_', ' ')})`;

export const describeCron = (expression: string, tz: string | undefined) => {
  const description = cronstrue.toString(expression, { verbose: true });
  return withTimeZone(
    description.charAt(0).toLowerCase() + description.slice(1),
    tz,
  );
};

export const formatTime = (hour: number, minute: number) =>
  [hour, minute].map((part) => String(part).padStart(2, '0')).join(':');

export const toDefaultWindow = (expression: string) => {
  const [, hour, ...days] = expression.split(' ');
  const start = Number(hour);
  return {
    start: formatTime(start, 0),
    end: formatTime((start + 1) % 24, 0),
    days: cronstrue
      .toString(['0', '0', ...days].join(' '), { verbose: true })
      .split(', ')
      .slice(1)
      .join(', '),
  };
};

export const describeSchedule = (
  cron: string,
  defaults: ScheduleDefaultsDto,
  tz: string | undefined,
) => {
  const preset = toSchedulePreset(cron);
  if (!preset) {
    return describeCron(cron, tz);
  }

  return withTimeZone(
    gt({
      message: 'between {start} and {end}, {days}',
      values: toDefaultWindow(defaults[preset]),
    }),
    tz,
  );
};
