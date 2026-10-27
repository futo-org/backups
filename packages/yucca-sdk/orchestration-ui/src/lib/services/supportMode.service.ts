import {
  getSupportMode,
  updateSupportMode,
  type SupportModeUpdateRequestDto,
} from '$lib/fetch-client';
import { queryClient } from '$lib/query-client';
import { handleError } from '$lib/utils/handle-error';
import { createMutation, createQuery } from '@tanstack/svelte-query';
import { gt } from 'svelte-i18n-lingui';

export const supportModeKeys = {
  all: ['support-mode'] as const,
};

export const maxSupportModeRuns = 20;

export const useSupportMode = () =>
  createQuery(
    () => ({
      queryKey: supportModeKeys.all,
      queryFn: () => getSupportMode(),
    }),
    () => queryClient,
  );

export const useUpdateSupportMode = () =>
  createMutation(
    () => ({
      mutationFn: (dto: SupportModeUpdateRequestDto) => updateSupportMode(dto),
      onSuccess: (supportMode) =>
        queryClient.setQueryData(supportModeKeys.all, supportMode),
      onError: (error) => handleError(error, gt`Failed to save support mode`),
    }),
    () => queryClient,
  );
