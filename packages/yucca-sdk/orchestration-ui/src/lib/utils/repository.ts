import type {
  InspectedLocalRepositoryDto,
  SnapshotDto,
} from '$lib/fetch-client';

export const latestSnapshot = (snapshots: SnapshotDto[] = []) =>
  snapshots.toSorted((a, b) => Date.parse(b.time) - Date.parse(a.time)).at(0);

export const isRestorable = ({ snapshots }: InspectedLocalRepositoryDto) =>
  !!snapshots?.length;

const restoreRank = (repository: InspectedLocalRepositoryDto) => {
  if (isRestorable(repository)) {
    return 0;
  }

  return repository.snapshots === undefined ? 1 : 2;
};

const latestBackupTime = ({ snapshots }: InspectedLocalRepositoryDto) => {
  const latest = latestSnapshot(snapshots);
  return latest ? Date.parse(latest.time) : 0;
};

export const sortRestoreCandidates = (
  repositories: InspectedLocalRepositoryDto[],
) =>
  repositories.toSorted(
    (a, b) =>
      restoreRank(a) - restoreRank(b) ||
      Number(b.name.includes('Immich')) - Number(a.name.includes('Immich')) ||
      latestBackupTime(b) - latestBackupTime(a),
  );
