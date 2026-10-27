import RelativeTime from '$lib/components/util/RelativeTime.svelte';
import { render } from 'svelte/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const now = Date.parse('2026-01-01T12:00:00Z');

const renderText = (time: string) =>
  render(RelativeTime, { props: { time } }).body.replaceAll(
    /<!--.*?-->|<[^>]+>/g,
    '',
  );

describe('RelativeTime', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(now);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('says a moment ago within the last minute', () => {
    expect(renderText(new Date(now - 30_000).toISOString())).toBe(
      'a moment ago',
    );
  });

  it('says how long ago an older time was', () => {
    expect(renderText(new Date(now - 5 * 60_000).toISOString())).toBe(
      '5 minutes ago',
    );
  });
});
