import { sdk } from '$lib';
import { createTicket } from '@futo-org/backups-api-client';
import RemoveDeletedRepositoryModal from '$lib/components/backups/dialogs/RemoveDeletedRepositoryModal.svelte';
import { handleDeleteRepository } from '$lib/services/repository.service';
import { modalManager, toastManager } from '@immich/ui';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('$lib', () => ({
  sdk: {
    futoBackupsCreateTicket: vi.fn(),
    futoBackupsDeleteRepository: vi.fn(),
    futoBackupsSyncRepositoryDeletion: vi.fn(),
  },
}));

vi.mock('@futo-org/backups-api-client', () => ({ createTicket: vi.fn() }));

vi.mock('@immich/ui', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@immich/ui')>()),
  toastManager: { danger: vi.fn() },
  modalManager: { show: vi.fn() },
}));

const httpError = (status: number) =>
  Object.assign(new Error(`Error: ${status}`), { status });

describe('handleDeleteRepository', () => {
  let focus: EventTarget;

  beforeEach(() => {
    vi.clearAllMocks();
    focus = new EventTarget();
    vi.useFakeTimers();
    vi.stubGlobal('window', {
      open: vi.fn(),
      addEventListener: focus.addEventListener.bind(focus),
      removeEventListener: focus.removeEventListener.bind(focus),
    });
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  const returnToTab = async () => {
    focus.dispatchEvent(new Event('focus'));
    await vi.advanceTimersByTimeAsync(0);
  };

  describe('when the repository still exists remotely', () => {
    beforeEach(() => {
      vi.mocked(sdk.futoBackupsCreateTicket).mockResolvedValue({
        redirectTo: 'https://idp.test/authorize',
      });
    });

    it('opens the ticket page', async () => {
      await handleDeleteRepository('repository-1', true);

      expect(window.open).toHaveBeenCalledWith(
        'https://idp.test/authorize',
        '_blank',
      );
      expect(sdk.futoBackupsDeleteRepository).not.toHaveBeenCalled();
    });

    it('removes the local repository once the ticket deleted it remotely', async () => {
      vi.mocked(sdk.futoBackupsSyncRepositoryDeletion)
        .mockResolvedValueOnce({ deleted: false })
        .mockResolvedValueOnce({ deleted: true });

      await handleDeleteRepository('repository-1', true);
      await returnToTab();
      await returnToTab();
      await returnToTab();

      expect(sdk.futoBackupsSyncRepositoryDeletion).toHaveBeenCalledTimes(2);
      expect(sdk.futoBackupsSyncRepositoryDeletion).toHaveBeenCalledWith(
        'repository-1',
      );
    });

    it('stops syncing the deletion after a while', async () => {
      await handleDeleteRepository('repository-1', true);
      vi.advanceTimersByTime(15 * 60 * 1000);
      await returnToTab();

      expect(sdk.futoBackupsSyncRepositoryDeletion).not.toHaveBeenCalled();
    });

    it('leaves deletions from the web app to the ticket page', async () => {
      vi.mocked(createTicket).mockResolvedValue({
        redirectTo: 'https://idp.test/authorize',
      });

      await handleDeleteRepository('repository-1');
      await returnToTab();

      expect(window.open).toHaveBeenCalledWith(
        'https://idp.test/authorize',
        '_blank',
      );
      expect(sdk.futoBackupsSyncRepositoryDeletion).not.toHaveBeenCalled();
    });
  });

  describe('when the repository is gone remotely', () => {
    beforeEach(() => {
      vi.mocked(sdk.futoBackupsCreateTicket).mockRejectedValue(httpError(410));
    });

    it('asks before removing it from this machine', async () => {
      vi.mocked(modalManager.show).mockResolvedValue(true as never);

      await handleDeleteRepository('repository-1', true);

      expect(modalManager.show).toHaveBeenCalledWith(
        RemoveDeletedRepositoryModal,
        {},
      );
      expect(sdk.futoBackupsDeleteRepository).toHaveBeenCalledWith(
        'repository-1',
      );
      expect(window.open).not.toHaveBeenCalled();
      expect(toastManager.danger).not.toHaveBeenCalled();
    });

    it('reports a failure to remove it from this machine', async () => {
      vi.mocked(modalManager.show).mockResolvedValue(true as never);
      vi.mocked(sdk.futoBackupsDeleteRepository).mockRejectedValue(
        httpError(500),
      );

      await expect(
        handleDeleteRepository('repository-1', true),
      ).rejects.toThrow('Error: 500');

      expect(toastManager.danger).toHaveBeenCalled();
    });

    it('keeps it when the removal is cancelled', async () => {
      vi.mocked(modalManager.show).mockResolvedValue(false as never);

      await handleDeleteRepository('repository-1', true);

      expect(modalManager.show).toHaveBeenCalled();
      expect(sdk.futoBackupsDeleteRepository).not.toHaveBeenCalled();
    });
  });

  it.each([404, 500])(
    'reports a %s without removing anything',
    async (status) => {
      vi.mocked(sdk.futoBackupsCreateTicket).mockRejectedValue(
        httpError(status),
      );

      await expect(
        handleDeleteRepository('repository-1', true),
      ).rejects.toThrow(`Error: ${status}`);

      expect(modalManager.show).not.toHaveBeenCalled();
      expect(sdk.futoBackupsDeleteRepository).not.toHaveBeenCalled();
      expect(toastManager.danger).toHaveBeenCalled();
    },
  );
});
