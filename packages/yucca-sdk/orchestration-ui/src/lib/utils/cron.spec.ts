import {
  describeCron,
  describeSchedule,
  isValidCron,
  resolveCron,
  runsMoreThanHourly,
} from '$lib/utils/cron';
import { DateTime, Settings } from 'luxon';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

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

describe('isValidCron', () => {
  it.each([
    '@daily',
    '@weekly',
    '@monthly',
    '@hourly',
    '0 3 * * *',
    '*/30 1-5 * * 1-5',
    '0 17 3 * * 4',
    '17 3 * * THU',
  ])('accepts %s', (cron) => {
    expect(isValidCron(cron)).toBe(true);
  });

  it.each(['invalid', '', '60 3 * * *'])('rejects %j', (cron) => {
    expect(isValidCron(cron)).toBe(false);
  });
});

describe('resolveCron', () => {
  const defaults = {
    daily: '23 3 * * *',
    weekly: '23 3 * * 2',
    monthly: '23 3 12 * *',
  };

  it.each([
    ['@daily', '23 3 * * *'],
    ['@weekly', '23 3 * * 2'],
    ['@monthly', '23 3 12 * *'],
    ['17 4 * * 4', '17 4 * * 4'],
  ])('resolves %s to %s', (cron, expected) => {
    expect(resolveCron(cron, defaults)).toBe(expected);
  });

  it('keeps a preset as written until the defaults have loaded', () => {
    expect(resolveCron('@weekly', undefined)).toBe('@weekly');
  });
});

describe('describeCron', () => {
  it('lowercases only the first letter so day names keep their capital', () => {
    expect(describeCron('23 3 * * 2', DateTime.local().zoneName)).toBe(
      'at 03:23 AM, only on Tuesday',
    );
  });
});

describe('schedule descriptions in the server time zone', () => {
  const { defaultZone } = Settings;
  const defaults = {
    daily: '23 3 * * *',
    weekly: '23 3 * * 2',
    monthly: '23 3 12 * *',
  };

  beforeEach(() => {
    Settings.defaultZone = 'Europe/London';
  });

  afterEach(() => {
    Settings.defaultZone = defaultZone;
  });

  it('names the server time zone readably when it differs from the local one', () => {
    expect(describeCron('0 3 * * *', 'America/New_York')).toBe(
      'at 03:00 AM, every day (America/New York)',
    );
  });

  it('leaves the description alone when the server shares the local time zone', () => {
    expect(describeCron('0 3 * * *', 'Europe/London')).toBe(
      'at 03:00 AM, every day',
    );
  });

  it('describes a preset as the window its installation default falls in', () => {
    expect(describeSchedule('@weekly', defaults, 'America/New_York')).toBe(
      'between 03:00 and 04:00, only on Tuesday (America/New York)',
    );
  });

  it('describes a custom expression at its exact time', () => {
    expect(describeSchedule('17 4 * * *', defaults, 'Europe/London')).toBe(
      'at 04:17 AM, every day',
    );
  });

  it('qualifies a preset when the server time zone is unknown', () => {
    expect(describeSchedule('@weekly', defaults, undefined)).toBe(
      'between 03:00 and 04:00, only on Tuesday (server time zone unavailable)',
    );
  });

  it('qualifies a custom expression when the server time zone is unknown', () => {
    expect(describeSchedule('17 4 * * *', defaults, undefined)).toBe(
      'at 04:17 AM, every day (server time zone unavailable)',
    );
  });
});
