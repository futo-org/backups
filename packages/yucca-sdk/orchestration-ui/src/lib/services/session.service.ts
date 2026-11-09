import {
  futoBackupsConnectDeviceAuthorize,
  futoBackupsConnectDeviceToken,
  futoBackupsCreateSession,
  futoBackupsSessionDeviceAuthorize,
  futoBackupsSessionDeviceToken,
} from '$lib/fetch-client';
import { queryClient } from '$lib/query-client';
import { handleError } from '$lib/utils/handle-error';
import { createMutation } from '@tanstack/svelte-query';
import { gt } from 'svelte-i18n-lingui';

export type DeviceFlowKind = 'oidc' | 'session';

export const deviceFlowEndpoints = {
  oidc: {
    authorize: futoBackupsConnectDeviceAuthorize,
    token: futoBackupsConnectDeviceToken,
  },
  session: {
    authorize: futoBackupsSessionDeviceAuthorize,
    token: futoBackupsSessionDeviceToken,
  },
};

export const useCreateSession = () =>
  createMutation(
    () => ({
      mutationFn: (token: string) => futoBackupsCreateSession({ token }),
      onError: (error) => handleError(error, gt`Failed to log in`),
    }),
    () => queryClient,
  );
