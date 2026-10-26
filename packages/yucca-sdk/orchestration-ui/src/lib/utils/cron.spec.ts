import { runsMoreThanHourly } from '$lib/utils/cron';
import { describe, expect, it } from 'vitest';

describe('runsMoreThanHourly', () => {
  it.each([
    '* 5 * * *',
    '* * * * *',
    '*/15 * * * *',
    '*/59 * * * *',
    '0,30 * * * *',
    '0-5 3 * * *',
    '5/10 * * * *',
  ])('flags %s', (cron) => {
    expect(runsMoreThanHourly(cron)).toBe(true);
  });

  it.each([
    '0 3 * * *',
    '0 * * * *',
    '30 */2 * * *',
    '15 3 * * 0',
    '*/60 * * * *',
    '0,0 * * * *',
    '0-0 * * * *',
    '',
  ])('accepts %s', (cron) => {
    expect(runsMoreThanHourly(cron)).toBe(false);
  });
});
