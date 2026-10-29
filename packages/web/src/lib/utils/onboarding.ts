import type {
  ConnectionDto,
  RepositoryMetricsDto,
} from '@futo-org/backups-api-client';

export type FirstBackupState = 'waiting' | 'running' | 'complete';

export type OnboardingProgress = {
  connected: boolean;
  connectionName?: string;
  connectionType?: ConnectionDto['type'];
  firstBackup: FirstBackupState;
  startedAt?: string;
};

type RepositoryWithMetrics = { metrics: RepositoryMetricsDto };

// lastBackupStatus is reset to 'incomplete' whenever a run starts, so only
// lastBackup (written when a run ends) proves a backup ever finished.
const hasFinishedABackup = ({ metrics }: RepositoryWithMetrics) =>
  !!metrics.lastBackup;

const isRunning = ({ metrics }: RepositoryWithMetrics) =>
  metrics.lastBackupStatus === 'incomplete' && !!metrics.lastStarted;

export const isOnboardingComplete = (repositories: RepositoryWithMetrics[]) =>
  repositories.some((repository) => hasFinishedABackup(repository));

const getFirstBackup = (
  repositories: RepositoryWithMetrics[],
): Pick<OnboardingProgress, 'firstBackup' | 'startedAt'> => {
  if (isOnboardingComplete(repositories)) {
    return { firstBackup: 'complete' };
  }

  const startedAt = repositories.find((repository) => isRunning(repository))
    ?.metrics.lastStarted;
  if (startedAt) {
    return { firstBackup: 'running', startedAt };
  }

  return { firstBackup: 'waiting' };
};

const getLatestSeenConnection = (connections: ConnectionDto[]) => {
  const seen = connections.flatMap(({ name, type, lastSeenAt }) =>
    lastSeenAt ? [{ name, type, lastSeenAt }] : [],
  );
  return seen
    .toSorted((a, b) => b.lastSeenAt.localeCompare(a.lastSeenAt))
    .at(0);
};

export const getOnboardingProgress = (
  connections: ConnectionDto[],
  repositories: RepositoryWithMetrics[],
): OnboardingProgress => {
  const latest = getLatestSeenConnection(connections);

  return {
    connected: !!latest || repositories.length > 0,
    connectionName: latest?.name,
    connectionType: latest?.type,
    ...getFirstBackup(repositories),
  };
};
