import type { BackupStatusType } from '$lib/components/backups/BackupStatus.svelte';
import CancelJobModal from '$lib/components/backups/dialogs/CancelJobModal.svelte';
import ViewStatusModal from '$lib/components/backups/dialogs/ViewStatusModal.svelte';
import { SocketEvent } from '$lib/events';
import {
  cancelJob,
  getJob,
  getJobs,
  type JobDto,
  type YuccaJobName,
  type JobProgressDto,
  type YuccaJobStatus,
} from '$lib/fetch-client';
import { getProvider } from '$lib/providers';
import { queryClient } from '$lib/query-client';
import { formatDuration } from '$lib/utils/format';
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
export type JobTickEvent = SocketEvent<{
  jobId: string;
  repositoryId: string;
  progress: JobProgressDto;
}>;

export const jobKeys = {
  byRepository: (id: string) => ['jobs', id] as const,
  byId: (id: string) => ['job', id] as const,
};

export const jobKinds: Record<
  YuccaJobName,
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
  status?: YuccaJobStatus,
): status is Exclude<YuccaJobStatus, 'queued' | 'running'> =>
  status !== undefined && status !== 'queued' && status !== 'running';

export const getRemainingText = (
  progress: JobProgressDto | undefined,
  now: number,
) => {
  if (!progress) {
    return '';
  }

  const { estimatedEndAt, bytesDone, totalBytes, percentDone, scanning } =
    progress;
  if (scanning) {
    return gt`Scanning files…`;
  }

  const finished =
    bytesDone && totalBytes ? bytesDone >= totalBytes : percentDone >= 1;

  if (estimatedEndAt === undefined && !finished) {
    return gt`Calculating time remaining…`;
  }

  const remaining = estimatedEndAt ? Date.parse(estimatedEndAt) - now : 0;
  if (finished || remaining <= 0) {
    return gt`Nearly done.`;
  }

  if (remaining < 60_000) {
    return gt`Less than a minute remaining`;
  }

  return gt({
    message: 'About {duration} remaining',
    values: {
      duration: formatDuration(Math.round(remaining / 60_000) * 60_000),
    },
  });
};

export const useJobs = (
  repositoryId: () => string | undefined,
  name?: YuccaJobName,
) =>
  createQuery(
    () => ({
      queryKey: jobKeys.byRepository(repositoryId() ?? ''),
      queryFn: () => getJobs(repositoryId()!).then(({ jobs }) => jobs),
      select: (jobs: JobDto[]) =>
        name ? jobs.filter((job) => job.name === name) : jobs,
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
          data
            ? [
                event.data.job,
                ...data.filter(({ id }) => id !== event.data.job.id),
              ]
            : void 0,
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
    onJobTick(event: JobTickEvent) {
      queryClient.setQueryData(
        jobKeys.byId(event.data.jobId),
        (data: JobDto | undefined) =>
          data ? { ...data, progress: event.data.progress } : void 0,
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
        Exclude<YuccaJobStatus, 'queued' | 'running'>,
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

export const handleCancelJob = async (
  jobId: string,
  type: BackupStatusType,
) => {
  const confirmed = await modalManager.show(CancelJobModal, { type });
  if (!confirmed) {
    return;
  }

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
    $if: () => job.name !== 'repository-sync-metrics',
  };

  const DownloadLog: ActionItem = {
    title: t(msg`Download Full Log`),
    onAction: () =>
      window.open(
        `${getProvider().baseUrl}/api/futo-backups/jobs/${job.id}/download`,
        '_blank',
      ),
  };

  const DownloadSupportLog: ActionItem = {
    title: t(msg`Download Support Log`),
    onAction: () =>
      window.open(
        `${getProvider().baseUrl}/api/futo-backups/jobs/${job.id}/support-log/download`,
        '_blank',
      ),
    $if: () => Boolean(job.outcome?.support),
  };

  return { ViewLog, DownloadLog, DownloadSupportLog };
};
