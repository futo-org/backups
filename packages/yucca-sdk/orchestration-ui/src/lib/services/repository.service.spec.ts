import { sdk } from '$lib';
import { handleDeleteRepository } from '$lib/services/repository.service';
import { toastManager } from '@immich/ui';
import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('$lib', () => ({
  sdk: { createTicket: vi.fn(), deleteRepository: vi.fn() },
}));

vi.mock('@immich/ui', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@immich/ui')>()),
  toastManager: { danger: vi.fn() },
}));

describe('handleDeleteRepository', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.stubGlobal('window', { open: vi.fn() });
  });

  it('opens the ticket page of a repository that still exists remotely', async () => {
    vi.mocked(sdk.createTicket).mockResolvedValue({
      redirectTo: 'https://idp.test/authorize',
    });

    await handleDeleteRepository('repository-1', true);

    expect(window.open).toHaveBeenCalledWith(
      'https://idp.test/authorize',
      '_blank',
    );
    expect(sdk.deleteRepository).not.toHaveBeenCalled();
  });

  it('removes a repository already deleted remotely from this server', async () => {
    vi.mocked(sdk.createTicket).mockRejectedValue(
      Object.assign(new Error('Error: 404'), { status: 404 }),
    );

    await handleDeleteRepository('repository-1', true);

    expect(sdk.deleteRepository).toHaveBeenCalledWith('repository-1');
    expect(window.open).not.toHaveBeenCalled();
    expect(toastManager.danger).not.toHaveBeenCalled();
  });

  it('reports other failures to start the deletion', async () => {
    vi.mocked(sdk.createTicket).mockRejectedValue(
      Object.assign(new Error('Error: 500'), { status: 500 }),
    );

    await expect(handleDeleteRepository('repository-1', true)).rejects.toThrow(
      'Error: 500',
    );

    expect(sdk.deleteRepository).not.toHaveBeenCalled();
    expect(toastManager.danger).toHaveBeenCalled();
  });
});
