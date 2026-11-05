import { formatDuration } from '$lib/utils/format';
import { describe, expect, it } from 'vitest';

const second = 1000;
const minute = 60 * second;
const hour = 60 * minute;
const day = 24 * hour;

describe('formatDuration', () => {
  it.each([
    [0, '<1s'],
    [400, '<1s'],
    [45 * second, '45s'],
    [59 * minute, '59m'],
    [hour, '1h'],
    [23 * hour + 59 * minute, '23h, 59m'],
    [day, '1d'],
    [6 * day, '6d'],
    [7 * day, '1w'],
    [29 * day, '4w, 1d'],
    [30 * day, '1M'],
    [365 * day, '1y'],
  ])('formats %d ms as %s', (ms, expected) => {
    expect(formatDuration(ms)).toBe(expected);
  });

  it('uses M for months so they are not mistaken for minutes', () => {
    expect(formatDuration(4 * 30 * day + 9 * minute)).toBe('4M, 9m');
  });

  it('shows only the three largest non-zero units', () => {
    expect(
      formatDuration(4 * 30 * day + 9 * day + 21 * hour + 9 * minute),
    ).toBe('4M, 1w, 2d');
    expect(formatDuration(3 * 7 * day + 6 * hour + 33 * minute)).toBe(
      '3w, 6h, 33m',
    );
    expect(formatDuration(day + 2 * hour + 3 * minute + 4 * second)).toBe(
      '1d, 2h, 3m',
    );
  });

  it('caps long durations at three units too', () => {
    expect(formatDuration(hour + 2 * minute + 3 * second, 'long')).toBe(
      '1 hour, 2 minutes, 3 seconds',
    );
    expect(
      formatDuration(30 * day + 2 * hour + 3 * minute + 4 * second, 'long'),
    ).toBe('1 month, 2 hours, 3 minutes');
  });
});
