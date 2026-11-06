import { sdk } from '$lib';
import { handleForgetSnapshot } from '$lib/services/snapshot.service';
import { toastManager } from '@immich/ui';
import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('$lib', () => ({
  sdk: { futoBackupsForgetSnapshot: vi.fn() },
}));

vi.mock('@immich/ui', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@immich/ui')>()),
  toastManager: {
    info: vi.fn(),
    success: vi.fn(),
    danger: vi.fn(),
    remove: vi.fn(),
  },
}));

describe('handleForgetSnapshot', () => {
  beforeEach(() => vi.clearAllMocks());

  it('shows a dismissible progress toast and removes it once the snapshot is deleted', async () => {
    await handleForgetSnapshot('repository-1', 'snapshot-1');

    expect(toastManager.info).toHaveBeenCalledWith(
      'Deleting snapshot',
      expect.objectContaining({ id: 'snapshot-1', closable: true }),
    );
    expect(sdk.futoBackupsForgetSnapshot).toHaveBeenCalledWith(
      'repository-1',
      'snapshot-1',
    );
    expect(toastManager.success).toHaveBeenCalledWith('Deleted snapshot');
    expect(
      (toastManager as never as { remove: unknown }).remove,
    ).toHaveBeenCalledWith({ id: 'snapshot-1' });
  });
});
