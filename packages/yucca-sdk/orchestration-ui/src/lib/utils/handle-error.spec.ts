import { toastManager } from '@immich/ui';
import { HttpError } from '@oazapfts/runtime';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { handleError } from '$lib/utils/handle-error';

vi.mock('@immich/ui', () => ({ toastManager: { danger: vi.fn() } }));

describe('handleError', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  it('labels messages from the server', () => {
    const error = new HttpError(
      500,
      { message: 'Repository is locked' },
      new Headers(),
    );

    expect(handleError(error, 'Failed to delete snapshot')).toBe(
      'Repository is locked\n(Yucca Server Error)',
    );
    expect(toastManager.danger).toHaveBeenCalledWith(
      'Repository is locked\n(Yucca Server Error)',
    );
  });

  it('shows the localized message for client-side fetch failures', () => {
    const error = new TypeError(
      'NetworkError when attempting to fetch resource.',
    );

    expect(handleError(error, 'Failed to delete snapshot')).toBe(
      'Failed to delete snapshot',
    );
    expect(toastManager.danger).toHaveBeenCalledWith(
      'Failed to delete snapshot',
    );
  });
});
