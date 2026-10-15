import ViewStatusModal from '$lib/components/backups/dialogs/ViewStatusModal.svelte';
import { SocketEvent } from '$lib/events';
import {
  cancelJob,
  getJob,
  getJobs,
  type JobDto,
  type JobName,
  type JobStatus,
} from '$lib/fetch-client';
import { getProvider } from '$lib/providers';
import { queryClient } from '$lib/query-client';
import { handleError } from '$lib/utils/handle-error';
import {
  modalManager,
  toastManager,
  type ActionItem,
  type ToastShow,
} from '@immich/ui';
import { createQuery } from '@tanstack/svelte-query';
import { gt, msg } from 'svelte-i18n-lingui';

export type JobCreateEvent = SocketEvent<{ job: JobDto }>;
export type JobUpdateEvent = SocketEvent<{
  jobId: string;
  repositoryId: string;
  job: Partial<JobDto>;
}>;

export const jobKeys = {
  byRepository: (id: string) => ['jobs', id] as const,
  byId: (id: string) => ['job', id] as const,
};

export const jobKinds: Record<
  JobName,
  'backup' | 'restore' | 'forget' | 'syncMetrics'
> = {
  'repository-backup': 'backup',
  'repository-prune': 'forget',
  'repository-restore': 'restore',
  'repository-restore-from-point': 'restore',
  'repository-snapshot-forget': 'forget',
  'repository-sync-metrics': 'syncMetrics',
};

export const isJobFinished = (
  status?: JobStatus,
): status is Exclude<JobStatus, 'queued' | 'running'> =>
  status !== undefined && status !== 'queued' && status !== 'running';

export const useJobs = (repositoryId: () => string | undefined) =>
  createQuery(
    () => ({
      queryKey: jobKeys.byRepository(repositoryId() ?? ''),
      queryFn: () => getJobs(repositoryId()!).then(({ jobs }) => jobs),
      enabled: repositoryId() !== undefined,
    }),
    () => queryClient,
  );

export const useJob = (jobId: string) =>
  createQuery(
    () => ({
      queryKey: jobKeys.byId(jobId),
      queryFn: () => getJob(jobId),
    }),
    () => queryClient,
  );

export const useJobEventHandler = () => {
  return {
    onJobCreate(event: JobCreateEvent) {
      queryClient.setQueryData(jobKeys.byId(event.data.job.id), event.data.job);
      queryClient.setQueryData(
        jobKeys.byRepository(event.data.job.repositoryId),
        (data: JobDto[] | undefined) =>
          data ? [event.data.job, ...data] : void 0,
      );
    },
    onJobUpdate(event: JobUpdateEvent) {
      queryClient.setQueryData(
        jobKeys.byId(event.data.jobId),
        (data: JobDto | undefined) =>
          data ? { ...data, ...event.data.job } : void 0,
      );
      queryClient.setQueryData(
        jobKeys.byRepository(event.data.repositoryId),
        (data: JobDto[] | undefined) =>
          data
            ? data.map((entry) =>
                entry.id === event.data.jobId
                  ? { ...entry, ...event.data.job }
                  : entry,
              )
            : void 0,
      );
    },
  };
};

export const useBackupJobMonitor = () => {
  const watching = new Set<string>();

  return {
    onJobCreate(event: JobCreateEvent) {
      if (event.data.job.name === 'repository-backup') {
        watching.add(event.data.job.id);
      }
    },
    onJobUpdate(event: JobUpdateEvent) {
      const { jobId, job } = event.data;
      if (!watching.has(jobId) || !isJobFinished(job.status)) {
        return;
      }

      watching.delete(jobId);

      const alerts: Record<
        Exclude<JobStatus, 'queued' | 'running'>,
        ToastShow
      > = {
        complete: {
          color: 'success',
          title: gt`Backup complete`,
          description: gt`Library successfully backed up.`,
        },
        warn: {
          color: 'warning',
          title: gt`Backup completed with warnings`,
          description: gt`Some files could not be backed up. Check the backup log for details.`,
        },
        failed: {
          color: 'danger',
          title: gt`Backup failed`,
          description: gt`Could not finish backing up.`,
        },
        cancelled: {
          color: 'secondary',
          title: gt`Backup cancelled`,
          description: gt`The backup was stopped before it finished.`,
        },
        incomplete: {
          color: 'warning',
          title: gt`Backup interrupted`,
          description: gt`The backup stopped before it could finish.`,
        },
      };

      toastManager.show(alerts[job.status], { closable: true });
    },
  };
};

export const handleCancelJob = async (jobId: string) => {
  try {
    await cancelJob(jobId);
  } catch (error) {
    handleError(error, gt`Failed to cancel task`);
    throw error;
  }
};

export const getJobActions = (job: JobDto, t: typeof gt) => {
  const ViewLog: ActionItem = {
    title: t(msg`View Log`),
    onAction: () => void modalManager.open(ViewStatusModal, { jobId: job.id }),
  };

  const DownloadLog: ActionItem = {
    title: t(msg`Download Full Log`),
    onAction: () =>
      window.open(
        `${getProvider().baseUrl}/api/yucca/jobs/${job.id}/download`,
        '_blank',
      ),
  };

  return { ViewLog, DownloadLog };
};
