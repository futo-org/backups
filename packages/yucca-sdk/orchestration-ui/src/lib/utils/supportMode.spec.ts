import { nextRunsDraft } from '$lib/utils/supportMode';
import { describe, expect, it } from 'vitest';

describe('nextRunsDraft', () => {
  it('follows runs being used up while the count is untouched', () => {
    expect(nextRunsDraft(1, 1, 0)).toBeUndefined();
    expect(nextRunsDraft(3, 3, 2)).toBe(2);
  });

  it('keeps a count the user is still editing', () => {
    expect(nextRunsDraft(5, 1, 0)).toBe(5);
  });
});
