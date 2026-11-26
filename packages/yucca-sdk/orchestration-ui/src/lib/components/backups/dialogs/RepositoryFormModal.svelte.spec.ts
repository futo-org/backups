import { sdk } from '$lib';
import {
  futoBackupsGetBackends,
  futoBackupsUpdateRepository,
  type RepositoryCreateResponseDto,
} from '$lib/fetch-client';
import { options } from '$lib/options';
import { configureYucca } from '$lib/providers';
import { queryClient } from '$lib/query-client';
import { repositoryKeys } from '$lib/services/repository.service';
import { modalManager } from '@immich/ui';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { page, userEvent } from 'vitest/browser';
import { render } from 'vitest-browser-svelte';
import ConfigureRepositoryModal from './ConfigureRepositoryModal.svelte';
import CreateRepositoryModal from './CreateRepositoryModal.svelte';

vi.mock('$lib/fetch-client', { spy: true });

vi.mock('$lib', () => ({
  sdk: {
    futoBackupsCreateRepository: vi.fn(),
    futoBackupsUpdateRepository: vi.fn(),
  },
}));

const nameInput = () =>
  page.getByRole('textbox', { name: 'Name', exact: true });
const saveButton = () =>
  page.getByRole('button', { name: 'Save', exact: true });

const pickPaths = async (paths: string[]) => {
  vi.spyOn(modalManager, 'show').mockImplementation((...args) => {
    const props = args[1] as unknown as { onSubmit: (next: string[]) => void };
    props.onSubmit(paths);
    return Promise.resolve(undefined as never);
  });
  await page.getByRole('button', { name: 'Add first path' }).click();
};

const submitDraft = async () => {
  await nameInput().fill('Photos');
  await pickPaths(['/photos']);
  await saveButton().click();
};

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(sdk.futoBackupsCreateRepository)
    .mockReset()
    .mockResolvedValue({ repository: { id: 'new' } } as never);
  vi.mocked(sdk.futoBackupsUpdateRepository).mockReset();
  queryClient.clear();
  configureYucca({ api: 'orchestrator', language: 'en' });
  options.advanced.set(false);
  vi.mocked(futoBackupsGetBackends).mockResolvedValue({ backends: [] });
  vi.spyOn(modalManager, 'open').mockResolvedValue(undefined as never);
});

afterEach(() => {
  vi.restoreAllMocks();
});

it('cancels a draft with selected paths without creating a repository', async () => {
  const onClose = vi.fn();
  await render(CreateRepositoryModal, { onClose });
  await nameInput().fill('Photos');
  await pickPaths(['/photos']);
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  expect(onClose).toHaveBeenCalledOnce();
  expect(sdk.futoBackupsCreateRepository).not.toHaveBeenCalled();
});

it('requires paths before creating a backup', async () => {
  await render(CreateRepositoryModal, { onClose: vi.fn() });
  await nameInput().fill('Photos');
  await saveButton().click();
  expect(sdk.futoBackupsCreateRepository).not.toHaveBeenCalled();
  await expect
    .element(page.getByRole('alert'))
    .toHaveTextContent('Select at least one backup path');
});

it('requires a name before creating a backup', async () => {
  await render(CreateRepositoryModal, { onClose: vi.fn() });
  await pickPaths(['/photos']);
  await saveButton().click();
  await expect.element(nameInput()).toBeInvalid();
  await expect
    .element(page.getByRole('alert'))
    .toHaveTextContent('Enter a name for this backup');
  expect(sdk.futoBackupsCreateRepository).not.toHaveBeenCalled();
});

it('rejects a whitespace-only name before creating anything', async () => {
  await render(CreateRepositoryModal, { onClose: vi.fn() });
  await nameInput().fill('   ');
  await pickPaths(['/photos']);
  await saveButton().click();
  await expect
    .element(page.getByRole('alert'))
    .toHaveTextContent('Enter a name for this backup');
  expect(sdk.futoBackupsCreateRepository).not.toHaveBeenCalled();
});

it('creates with the selected paths and WORM in one request without opening configuration', async () => {
  const onClose = vi.fn();
  queryClient.setQueryData(repositoryKeys.all, []);
  await render(CreateRepositoryModal, { onClose });
  await page.getByRole('checkbox', { name: 'Write once (WORM)' }).click();
  await submitDraft();
  await vi.waitFor(() => expect(onClose).toHaveBeenCalledOnce());
  expect(sdk.futoBackupsCreateRepository).toHaveBeenCalledExactlyOnceWith({
    name: 'Photos',
    worm: true,
    paths: ['/photos'],
  });
  expect(sdk.futoBackupsUpdateRepository).not.toHaveBeenCalled();
  expect(modalManager.open).not.toHaveBeenCalled();
  expect(modalManager.show).toHaveBeenCalledOnce();
  expect(queryClient.getQueryState(repositoryKeys.all)?.isInvalidated).toBe(
    true,
  );
});

it('requires a path again after the last selected path is removed', async () => {
  await render(CreateRepositoryModal, { onClose: vi.fn() });
  await nameInput().fill('Photos');
  await pickPaths(['/photos']);
  await page
    .getByRole('button', { name: 'Remove /photos', exact: true })
    .click();
  await saveButton().click();
  await expect
    .element(page.getByRole('alert'))
    .toHaveTextContent('Select at least one backup path');
  expect(sdk.futoBackupsCreateRepository).not.toHaveBeenCalled();
});

it.each([
  ['a validation rejection', { status: 400 }],
  ['a server error', { status: 500 }],
  ['a lost connection', new TypeError('Failed to fetch')],
])('keeps the draft retryable after %s', async (_, failure) => {
  const onClose = vi.fn();
  vi.mocked(sdk.futoBackupsCreateRepository).mockRejectedValueOnce(failure);
  await render(CreateRepositoryModal, { onClose });
  await submitDraft();
  await expect.element(saveButton()).toBeEnabled();
  await expect.element(nameInput()).toHaveValue('Photos');
  expect(onClose).not.toHaveBeenCalled();
  await saveButton().click();
  await vi.waitFor(() => expect(onClose).toHaveBeenCalledOnce());
  expect(sdk.futoBackupsCreateRepository).toHaveBeenCalledTimes(2);
});

it('prevents changes while creation is pending', async () => {
  const onClose = vi.fn();
  const creation = Promise.withResolvers<RepositoryCreateResponseDto>();
  vi.mocked(sdk.futoBackupsCreateRepository).mockReturnValue(creation.promise);
  await render(CreateRepositoryModal, { onClose });
  await submitDraft();
  await expect.element(nameInput()).toBeDisabled();
  await expect.element(saveButton()).toBeDisabled();
  creation.resolve({ repository: { id: 'new' } } as never);
  await vi.waitFor(() => expect(onClose).toHaveBeenCalledOnce());
  expect(sdk.futoBackupsCreateRepository).toHaveBeenCalledOnce();
});

it('edits remote repositories without requiring local paths', async () => {
  const onClose = vi.fn();
  configureYucca({ api: 'customer', language: 'en' });
  const update = vi.mocked(futoBackupsUpdateRepository);
  update.mockResolvedValue({ repository: { id: 'remote' } } as never);
  await render(ConfigureRepositoryModal, {
    repository: { id: 'remote', name: 'Remote' } as never,
    onClose,
  });
  await nameInput().fill('Renamed');
  await saveButton().click();
  await vi.waitFor(() => expect(onClose).toHaveBeenCalledOnce());
  expect(update).toHaveBeenCalledWith('remote', { name: 'Renamed', paths: [] });
  expect(sdk.futoBackupsCreateRepository).not.toHaveBeenCalled();
  await expect
    .element(page.getByRole('button', { name: 'Add first path' }))
    .not.toBeInTheDocument();
});

it.each([{ paths: ['/photos'] }, { paths: [] }])(
  'preserves local paths $paths when renaming a configured backup',
  async ({ paths }) => {
    const onClose = vi.fn();
    vi.mocked(sdk.futoBackupsUpdateRepository).mockResolvedValue({
      repository: { id: 'local' },
    } as never);
    await render(ConfigureRepositoryModal, {
      repository: {
        id: 'local',
        name: 'Photos',
        configuration: { paths },
      } as never,
      onClose,
    });
    await nameInput().fill('Pictures');
    await saveButton().click();
    await vi.waitFor(() => expect(onClose).toHaveBeenCalledOnce());
    expect(sdk.futoBackupsUpdateRepository).toHaveBeenCalledWith('local', {
      name: 'Pictures',
      paths,
    });
    expect(sdk.futoBackupsCreateRepository).not.toHaveBeenCalled();
  },
);

it('allows keyboard access to the backup options and path picker', async () => {
  await render(CreateRepositoryModal, { onClose: vi.fn() });
  await nameInput().click();
  await userEvent.tab();
  await expect
    .element(page.getByRole('checkbox', { name: 'Write once (WORM)' }))
    .toHaveFocus();
  await userEvent.tab();
  await expect
    .element(page.getByRole('button', { name: 'Add first path' }))
    .toHaveFocus();
});

it('keeps creation unsubmitted when the path picker is cancelled', async () => {
  await render(CreateRepositoryModal, { onClose: vi.fn() });
  await nameInput().fill('Photos');
  vi.spyOn(modalManager, 'show').mockResolvedValue(undefined as never);
  await page.getByRole('button', { name: 'Add first path' }).click();
  await saveButton().click();
  await expect
    .element(page.getByRole('alert'))
    .toHaveTextContent('Select at least one backup path');
  await expect.element(nameInput()).toHaveValue('Photos');
  expect(sdk.futoBackupsCreateRepository).not.toHaveBeenCalled();
});
