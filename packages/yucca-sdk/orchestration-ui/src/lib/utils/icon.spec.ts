import { toIconPath } from '$lib/utils/icon';
import warningSvg from '@material-symbols/svg-400/outlined/warning-fill.svg?raw';
import { describe, expect, it } from 'vitest';

describe('toIconPath', () => {
  it('reads the path data from a Material Symbols svg', () => {
    expect(toIconPath(warningSvg)).toMatch(/^m40-120 440-760 440 760H40Z/);
  });

  it('returns an empty path when the svg has no path', () => {
    expect(toIconPath('<svg xmlns="http://www.w3.org/2000/svg"></svg>')).toBe(
      '',
    );
  });
});
