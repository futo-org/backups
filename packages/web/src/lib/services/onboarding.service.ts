import { isOnboardingComplete } from '$lib/utils/onboarding';
import {
  getRepositories,
  listConnections,
  type ConnectionDto,
  type RepositoryWithMetricsDto,
} from '@futo-org/backups-api-client';
import { queryClient, repositoryKeys } from '@futo-org/backups-orchestrator-ui';
import { createQuery } from '@tanstack/svelte-query';

export const ONBOARDING_POLL_INTERVAL_MS = 15_000;

export const connectionKeys = {
  all: ['connections'] as const,
};

const pollUntilOnboarded = () =>
  isOnboardingComplete(
    queryClient.getQueryData<RepositoryWithMetricsDto[]>(repositoryKeys.all) ??
      [],
  )
    ? false
    : ONBOARDING_POLL_INTERVAL_MS;

export const useOnboardingConnections = (initialData: ConnectionDto[]) =>
  createQuery(
    () => ({
      queryKey: connectionKeys.all,
      queryFn: () => listConnections().then(({ connections }) => connections),
      initialData,
      refetchInterval: pollUntilOnboarded,
    }),
    () => queryClient,
  );

export const useOnboardingRepositories = (
  initialData: RepositoryWithMetricsDto[],
) =>
  createQuery(
    () => ({
      queryKey: repositoryKeys.all,
      queryFn: () => getRepositories().then(({ repositories }) => repositories),
      initialData,
      refetchInterval: pollUntilOnboarded,
    }),
    () => queryClient,
  );
