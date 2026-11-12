import cronstrue from 'cronstrue';

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

export const resolveCron = (
  cron: string,
  defaults: Record<SchedulePreset, string> | undefined,
) => {
  const preset = toSchedulePreset(cron);
  return (preset && defaults?.[preset]) ?? cron;
};

export const describeCron = (expression: string) => {
  const description = cronstrue.toString(expression, { verbose: true });
  return description.charAt(0).toLowerCase() + description.slice(1);
};
