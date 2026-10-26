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
