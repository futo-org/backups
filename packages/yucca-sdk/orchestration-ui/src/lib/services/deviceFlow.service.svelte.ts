import type {
  DeviceFlowFailureReason,
  DeviceFlowPollDto,
} from '$lib/fetch-client';
import { queryClient } from '$lib/query-client';
import {
  deviceFlowEndpoints,
  type DeviceFlowKind,
} from '$lib/services/session.service';
import { createQuery } from '@tanstack/svelte-query';
import { gt, msg } from 'svelte-i18n-lingui';

const DEFAULT_POLL_INTERVAL_SECONDS = 5;
const SLOW_DOWN_BACKOFF_SECONDS = 5;

const failures: Record<string, string> = {
  NOT_CONNECTED: msg`This instance is not connected to a FUTO Backups account yet.`,
  DEVICE_FLOW_FAILED: msg`Login was cancelled or timed out.`,
  WRONG_ACCOUNT: msg`That account does not own this instance. Log in with the account it was connected with.`,
  UNKNOWN: msg`Could not reach FUTO Backups. Check your connection.`,
};

export function createDeviceFlow(
  kind: DeviceFlowKind,
  handlers: {
    createSession: (token: string) => Promise<unknown>;
    onComplete: (result: DeviceFlowPollDto) => void;
    onFailure?: (message: string) => void;
  },
) {
  const { authorize, token } = deviceFlowEndpoints[kind];

  const state = $state<{
    userCode: string | undefined;
    verificationUri: string | undefined;
    deviceCode: string | undefined;
    interval: number;
    polling: boolean;
    error: string | undefined;
    pending: boolean;
    opened: boolean;
  }>({
    userCode: undefined,
    verificationUri: undefined,
    deviceCode: undefined,
    interval: DEFAULT_POLL_INTERVAL_SECONDS,
    polling: false,
    error: undefined,
    pending: false,
    opened: false,
  });

  let firstPoll: ReturnType<typeof setTimeout> | undefined;
  let attempt = 0;

  const poll = createQuery(
    () => ({
      queryKey: ['device-flow', kind, state.deviceCode],
      queryFn: async () => {
        const result = await token({ deviceCode: state.deviceCode! });
        if (result.status === 'SLOW_DOWN') {
          state.interval += SLOW_DOWN_BACKOFF_SECONDS;
        }

        return result;
      },
      enabled: state.polling && !!state.deviceCode,
      refetchInterval: (query) => {
        const status = query.state.data?.status;
        return status === 'SUCCESS' || status === 'FAILURE'
          ? false
          : state.interval * 1000;
      },
      refetchIntervalInBackground: true,
      refetchOnWindowFocus: false,
      retry: false,
      gcTime: 0,
    }),
    () => queryClient,
  );

  const stop = () => {
    attempt++;
    clearTimeout(firstPoll);
    state.polling = false;
    state.deviceCode = undefined;
  };

  const fail = (reason: DeviceFlowFailureReason | undefined) => {
    stop();
    state.pending = false;
    state.userCode = undefined;
    state.error = gt(failures[reason ?? 'UNKNOWN']);
    handlers.onFailure?.(state.error);
  };

  const complete = async (result: DeviceFlowPollDto) => {
    stop();

    if (result.accessToken) {
      await handlers.createSession(result.accessToken);
    }

    state.pending = false;
    handlers.onComplete(result);
  };

  $effect(() => {
    if (!state.polling) {
      return;
    }

    if (poll.isError) {
      fail('UNKNOWN');
      return;
    }

    const result = poll.data;
    switch (result?.status) {
      case 'SUCCESS': {
        void complete(result);
        break;
      }
      case 'FAILURE': {
        fail(result.reason);
        break;
      }
    }
  });

  const start = () => {
    stop();

    state.userCode = undefined;
    state.error = undefined;
    state.pending = true;
    state.opened = false;

    const current = attempt;
    authorize()
      .then((started) => {
        if (current !== attempt) {
          return;
        }

        state.userCode = started.userCode;
        state.verificationUri =
          started.verificationUriComplete ?? started.verificationUri;
        state.deviceCode = started.deviceCode;
        state.interval = started.interval ?? DEFAULT_POLL_INTERVAL_SECONDS;
        firstPoll = setTimeout(() => {
          state.polling = true;
        }, state.interval * 1000);
      })
      .catch((error: unknown) => {
        if (current !== attempt) {
          return;
        }

        const { status } = error as { status?: number };
        fail(
          kind === 'session' && status === 400 ? 'NOT_CONNECTED' : 'UNKNOWN',
        );
      });
  };

  const open = () => {
    if (!state.verificationUri) {
      return;
    }

    state.opened = true;
    window.open(state.verificationUri, 'futo-backups-device');
  };

  return {
    state,
    start,
    stop,
    open,
  };
}

export type DeviceFlow = ReturnType<typeof createDeviceFlow>;
