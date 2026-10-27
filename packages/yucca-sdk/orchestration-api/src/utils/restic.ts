import type { BackupMessage, RestoreMessage } from '@futo-org/restic-wrapper';

export type RetentionPolicy = {
  keepLast?: number;
  keepWithin?: string;
  keepWithinHourly?: string;
  keepWithinDaily?: string;
  keepWithinWeekly?: string;
  keepWithinMonthly?: string;
  keepWithinYearly?: string;
};

export const DEFAULT_RETENTION_POLICY: RetentionPolicy = {
  keepWithin: '60d',
};

export const createSampledLogWriter = <T extends BackupMessage | RestoreMessage>(
  log: ((event: T) => void) | undefined,
) => {
  let lastAt = 0;
  let lastPercent = -1;

  return (event: T) => {
    if (!log || event.message_type === 'verbose_status') {
      return;
    }

    if (event.message_type === 'status') {
      const percent = event.percent_done;
      if (percent < 1 && Date.now() - lastAt < 1000 && Math.abs(percent - lastPercent) < 0.01) {
        return;
      }

      lastAt = Date.now();
      lastPercent = percent;
    }

    log(event);
  };
};
