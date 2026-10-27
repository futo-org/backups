import { SocketEvent } from '$lib/events';
import type {
  JobDto,
  JobProgressDto,
  YuccaJobName,
  YuccaJobStatus,
} from '$lib/fetch-client';
import {
  getRemainingText,
  useBackupJobMonitor,
} from '$lib/services/job.service';
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

const now = Date.parse('2026-01-01T12:00:00Z');

const progress = (overrides: Partial<JobProgressDto> = {}): JobProgressDto => ({
  percentDone: 0.5,
  scanning: false,
  bytesDone: 50,
  totalBytes: 100,
  currentFiles: [],
  ...overrides,
});

const endingIn = (milliseconds: number) =>
  new Date(now + milliseconds).toISOString();

describe('getRemainingText', () => {
  it('says nothing without progress', () => {
    expect(getRemainingText(undefined, now)).toBe('');
  });

  it('says files are being scanned before restic has counted them', () => {
    expect(
      getRemainingText(
        progress({ scanning: true, estimatedEndAt: endingIn(600_000) }),
        now,
      ),
    ).toBe('Scanning files…');
  });

  it('says the time is being calculated before the first estimate', () => {
    expect(getRemainingText(progress(), now)).toBe(
      'Calculating time remaining…',
    );
  });

  it('says nearly done once every byte is uploaded', () => {
    expect(
      getRemainingText(progress({ bytesDone: 100, percentDone: 1 }), now),
    ).toBe('Nearly done.');
  });

  it('says nearly done once the estimated end has passed', () => {
    expect(
      getRemainingText(progress({ estimatedEndAt: endingIn(-5000) }), now),
    ).toBe('Nearly done.');
  });

  it('says less than a minute in the final minute', () => {
    expect(
      getRemainingText(progress({ estimatedEndAt: endingIn(45_000) }), now),
    ).toBe('Less than a minute remaining');
  });

  it('rounds the time left to the nearest minute', () => {
    expect(
      getRemainingText(
        progress({ estimatedEndAt: endingIn(150_000 + 29_000) }),
        now,
      ),
    ).toBe(
      getRemainingText(progress({ estimatedEndAt: endingIn(180_000) }), now),
    );
  });
});
