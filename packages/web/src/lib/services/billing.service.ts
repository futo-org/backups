import { handleError } from '$lib/utils/handle-error';
import {
  getBillingStatus,
  listBillingStatements,
  openSubscriptionPortal,
  startSubscription,
  type BillingStatusDto,
} from '@futo-org/backups-api-client';
import { queryClient } from '@futo-org/backups-orchestrator-ui';
import { createMutation, createQuery } from '@tanstack/svelte-query';

export const billingKeys = {
  status: () => ['billing', 'status'] as const,
  statements: () => ['billing', 'statements'] as const,
};

export const useBillingStatus = (initialData?: BillingStatusDto) =>
  createQuery(
    () => ({
      queryKey: billingKeys.status(),
      queryFn: () => getBillingStatus({ refresh: false }),
      initialData,
      // Pay's notifications update yucca's cached state within seconds of a
      // change (a cancellation on Pay's page, a failed charge); re-read that
      // cache while the page is open so it shows without a reload. This is
      // yucca's own database, never a call to Pay
      refetchInterval: 15_000,
      refetchOnWindowFocus: true,
    }),
    () => queryClient,
  );

export const useBillingStatements = () =>
  createQuery(
    () => ({
      queryKey: billingKeys.statements(),
      queryFn: () => listBillingStatements(),
    }),
    () => queryClient,
  );

export const useStartSubscription = () =>
  createMutation(
    () => ({
      mutationFn: () => startSubscription(),
      onError: (error) =>
        handleError(error, 'Failed to start the subscription'),
    }),
    () => queryClient,
  );

export const useSubscriptionPortal = () =>
  createMutation(
    () => ({
      mutationFn: () => openSubscriptionPortal(),
      onError: (error) =>
        handleError(error, 'Failed to open the subscription portal'),
    }),
    () => queryClient,
  );
