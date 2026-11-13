import {
  describeCron,
  isValidCron,
  resolveCron,
  runsMoreThanHourly,
} from '$lib/utils/cron';
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
    expect(describeCron('23 3 * * 2')).toBe('at 03:23 AM, only on Tuesday');
  });
});
