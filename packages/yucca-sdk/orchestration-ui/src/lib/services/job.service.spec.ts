import { SocketEvent } from '$lib/events';
import type { JobDto, YuccaJobName, YuccaJobStatus } from '$lib/fetch-client';
import { useBackupJobMonitor } from '$lib/services/job.service';
import { toastManager } from '@immich/ui';
import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('$lib', () => ({ sdk: {} }));

vi.mock('@immich/ui', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@immich/ui')>()),
  toastManager: { show: vi.fn() },
}));

const createJob = (id: string, name: YuccaJobName) =>
  new SocketEvent('JobCreate', {
    job: { id, name, repositoryId: 'repository-1' } as JobDto,
  });

const updateJob = (jobId: string, status: YuccaJobStatus) =>
  new SocketEvent('JobUpdate', {
    jobId,
    repositoryId: 'repository-1',
    job: { status },
  });

describe('useBackupJobMonitor', () => {
  beforeEach(() => vi.clearAllMocks());

  it.each([
    ['complete', 'success', 'Backup complete'],
    ['warn', 'warning', 'Backup completed with warnings'],
    ['failed', 'danger', 'Backup failed'],
    ['cancelled', 'secondary', 'Backup cancelled'],
    ['incomplete', 'warning', 'Backup interrupted'],
  ] as const)('shows a %s backup as a %s alert', (status, color, title) => {
    const monitor = useBackupJobMonitor();

    monitor.onJobCreate(createJob('job-1', 'repository-backup'));
    monitor.onJobUpdate(updateJob('job-1', status));

    expect(toastManager.show).toHaveBeenCalledWith(
      expect.objectContaining({ color, title }),
      { closable: true },
    );
  });

  it('alerts once per backup, after it stops running', () => {
    const monitor = useBackupJobMonitor();

    monitor.onJobCreate(createJob('job-1', 'repository-backup'));
    monitor.onJobUpdate(updateJob('job-1', 'running'));
    expect(toastManager.show).not.toHaveBeenCalled();

    monitor.onJobUpdate(updateJob('job-1', 'complete'));
    monitor.onJobUpdate(updateJob('job-1', 'complete'));
    expect(toastManager.show).toHaveBeenCalledTimes(1);
  });

  it('ignores other jobs and jobs it did not see queued', () => {
    const monitor = useBackupJobMonitor();

    monitor.onJobCreate(createJob('job-1', 'repository-restore'));
    monitor.onJobCreate(createJob('job-2', 'repository-prune'));
    monitor.onJobUpdate(updateJob('job-1', 'complete'));
    monitor.onJobUpdate(updateJob('job-2', 'complete'));
    monitor.onJobUpdate(updateJob('job-3', 'complete'));

    expect(toastManager.show).not.toHaveBeenCalled();
  });
});
