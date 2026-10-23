import { Kysely } from 'kysely';
import { basename, join } from 'node:path';

type Database = {
  runHistory: {
    id: string;
    repositoryId: string | null;
    start: string | null;
    end: string | null;
    logFilePath: string | null;
    status: string | null;
    type: 'backup' | 'restore' | 'forget';
  };
  jobs: {
    id: string;
    name: string;
    repositoryId: string;
    data: string;
    status: string;
    logFilePath: string;
    queuedAt: string;
    start: string | null;
    end: string | null;
  };
};

const jobNames = {
  backup: 'repository-backup',
  restore: 'repository-restore',
  forget: 'repository-prune',
};

const chunkSize = 500;

export async function up(db: Kysely<Database>): Promise<void> {
  const runs = await db
    .selectFrom('runHistory')
    .selectAll()
    .where('repositoryId', 'is not', null)
    .$narrowType<{ repositoryId: string }>()
    .execute();

  for (let index = 0; index < runs.length; index += chunkSize) {
    await db
      .insertInto('jobs')
      .values(
        runs.slice(index, index + chunkSize).map((run) => ({
          id: run.id,
          name: jobNames[run.type],
          repositoryId: run.repositoryId,
          data: JSON.stringify({ repositoryId: run.repositoryId }),
          status: run.status === 'incomplete' && run.type === 'backup' ? 'running' : (run.status ?? 'incomplete'),
          logFilePath: run.logFilePath
            ? join('logs', run.repositoryId, basename(run.logFilePath))
            : join('logs', 'jobs', `${run.id}.jsonl`),
          queuedAt: run.start ?? run.end ?? '',
          start: run.start,
          end: run.end,
        })),
      )
      .execute();
  }
}

export async function down(db: Kysely<Database>): Promise<void> {
  await db.deleteFrom('jobs').where('id', 'in', db.selectFrom('runHistory').select('id')).execute();
}
