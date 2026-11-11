import ImmichResticMissingAlert from '$lib/components/integrations/immich/ImmichResticMissingAlert.svelte';
import type { ImmichBackupStatusDto } from '$lib/fetch-client';
import { queryClient } from '$lib/query-client';
import { immichBackupStatusKeys } from '$lib/services/immich.integration.service';
import { render } from 'svelte/server';
import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('$lib/fetch-client');

const isAlertShown = (status: ImmichBackupStatusDto) => {
  queryClient.setQueryData(immichBackupStatusKeys.all, status);
  const { body } = render(ImmichResticMissingAlert);

  return body.replaceAll(/<!--.*?-->/g, '') !== '';
};

describe('ImmichResticMissingAlert', () => {
  beforeEach(() => queryClient.clear());

  it('shows when restic is missing', () => {
    expect(isAlertShown({ resticAvailable: false })).toBe(true);
  });

  it('hides when restic is available', () => {
    expect(isAlertShown({ resticAvailable: true })).toBe(false);
  });
});
