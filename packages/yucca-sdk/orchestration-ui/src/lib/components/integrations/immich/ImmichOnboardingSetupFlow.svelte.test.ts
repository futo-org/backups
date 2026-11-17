import ImmichOnboardingSetupFlow from './ImmichOnboardingSetupFlow.svelte';
import '../../../../routes/layout.css';
import type { OnboardingStatusResponseDto } from '$lib/fetch-client';
import { createRawSnippet } from 'svelte';
import { page } from 'vitest/browser';
import { render } from 'vitest-browser-svelte';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { handleStartYuccaLogin } from '$lib/services/backend.service';
import { useConfigureAndStartImmichIntegration } from '$lib/services/integrations.service';
import {
  handleConfirmRecoveryKey,
  handleCurrentRecoveryKey,
  handleOnboardingStatus,
} from '$lib/services/onboarding.service';
import { handleCreateBackup } from '$lib/services/repository.service';
import { scheduleKeys } from '$lib/services/schedule.service';
import { queryClient } from '$lib/query-client';

const recoveryKey = 'abcd 1234 efgh 5678';
const configure = vi.fn();

vi.mock('$lib/fetch-client');
vi.mock('$lib/services/onboarding.service', { spy: true });
vi.mock('$lib/services/backend.service', { spy: true });
vi.mock('$lib/services/integrations.service', { spy: true });
vi.mock('$lib/services/repository.service', { spy: true });

const button = (name: string) =>
  page.getByRole('button', { name, exact: true });

const tick = (name: string) => page.getByRole('checkbox', { name }).click();

const startSetup = async (status: Partial<OnboardingStatusResponseDto>) => {
  vi.mocked(handleOnboardingStatus).mockResolvedValue({
    status: 'ready',
    requiresAuthentication: false,
    isAuthenticated: true,
    hasTelemetry: 'full',
    hasBackend: false,
    hasOnboardedKey: true,
    hasBackup: false,
    hasSchedule: false,
    hasSkippedExtraConfig: false,
    ...status,
  } as OnboardingStatusResponseDto);
  await render(ImmichOnboardingSetupFlow, {
    fallback: createRawSnippet((onStart: () => () => void) => ({
      render: () => '<button>Set up backups</button>',
      setup: (element) => element.addEventListener('click', () => onStart()()),
    })),
    children: createRawSnippet(() => ({
      render: () => '<p>Backups dashboard</p>',
    })),
  });
  await button('Set up backups').click();
};

const openBetaDisclaimer = async () => {
  await startSetup({});
  await button('Confirm').click();
  await button('Connect account').click();
  await expect
    .element(page.getByText('FUTO Backups is in closed beta'))
    .toBeVisible();
};

const createBackup = async () => {
  await tick('I understand my beta backups may be deleted.');
  await button('Create backup').click();
  await expect.element(page.getByText('Start your first backup')).toBeVisible();
};

describe('Immich onboarding', () => {
  beforeEach(() => {
    vi.mocked(handleStartYuccaLogin).mockImplementation((onCreate) =>
      onCreate?.('backend'),
    );
    vi.mocked(handleCurrentRecoveryKey).mockResolvedValue({ recoveryKey });
    vi.mocked(handleConfirmRecoveryKey).mockResolvedValue();
    vi.mocked(handleCreateBackup).mockResolvedValue({ jobId: 'job' });
    configure.mockClear();
    const integration = {
      isPending: false,
      mutate: (
        _: undefined,
        { onSuccess }: { onSuccess: (data: { repositoryId: string }) => void },
      ) => {
        configure();
        onSuccess({ repositoryId: 'repository' });
      },
    } as unknown as ReturnType<typeof useConfigureAndStartImmichIntegration>;
    vi.mocked(useConfigureAndStartImmichIntegration).mockReturnValue(
      integration,
    );
    queryClient.setQueryData(scheduleKeys.all, {
      schedules: [],
      defaults: {
        daily: '0 3 * * *',
        weekly: '0 3 * * 0',
        monthly: '0 3 1 * *',
      },
    });
    vi.mocked(handleConfirmRecoveryKey).mockClear();
    vi.mocked(handleCreateBackup).mockClear();
  });

  it('runs a new installation through every step to its first backup', async () => {
    await startSetup({ hasTelemetry: 'none', hasOnboardedKey: false });
    await button('Continue').click();
    await button('Confirm').click();
    await button('Connect account').click();
    await tick('I saved my recovery key somewhere safe.');
    await button('Continue').click();
    await page.getByRole('textbox', { name: 'Recovery Key' }).fill(recoveryKey);
    await button('Confirm').click();
    await expect
      .element(page.getByText('FUTO Backups is in closed beta'))
      .toBeVisible();
    await createBackup();
    await button('Start backup').click();
    await expect.element(page.getByText('Backups dashboard')).toBeVisible();
    expect(handleConfirmRecoveryKey).toHaveBeenCalledOnce();
    expect(configure).toHaveBeenCalledOnce();
    expect(handleCreateBackup).toHaveBeenCalledExactlyOnceWith('repository');
  });

  it('keeps the created backup without starting it when the first backup dialog is closed', async () => {
    await openBetaDisclaimer();
    await createBackup();
    await button('Close').click();
    await expect.element(page.getByText('Backups dashboard')).toBeVisible();
    expect(configure).toHaveBeenCalledOnce();
    expect(handleCreateBackup).not.toHaveBeenCalled();
  });

  it('creates nothing when the beta disclaimer is closed', async () => {
    await openBetaDisclaimer();
    await button('Close').click();
    await expect.element(button('Set up backups')).toBeVisible();
    expect(configure).not.toHaveBeenCalled();
  });
});
