import { createPostgres } from '@immich/sql-tools';
import { Kysely, sql } from 'kysely';
import { PostgresJSDialect } from 'kysely-postgres-js';
import { DatabaseRepository } from '../src/repositories/database.repository.js';
import { LoggingRepository } from '../src/repositories/logging.repository.js';
import { StorageRepository } from '../src/repositories/storage.repository.js';
import type { DB } from '../src/schema/index.js';

const connectTo = (database: string, onClose?: () => void) => {
  const dialect = new PostgresJSDialect({
    postgres: createPostgres({
      onClose,
      connection: {
        connectionType: 'parts',
        host: process.env.POSTGRES_HOST ?? 'localhost',
        port: Number(process.env.POSTGRES_PORT ?? 15_432),
        username: process.env.POSTGRES_USERNAME ?? 'postgres',
        password: process.env.POSTGRES_PASSWORD ?? 'postgres',
        database,
      },
    }),
  });

  return new Kysely<DB>({ dialect });
};

const LEADER_LOCK = 'futo_backups_module_config';

const workers: Array<Kysely<DB>> = [];
const releases: Array<() => Promise<void>> = [];
const databaseName = process.env.POSTGRES_DATABASE ?? 'yucca';

const startWorker = (name = databaseName, onClose?: () => void) => {
  const db = connectTo(name, onClose);
  const database = new DatabaseRepository(db, new StorageRepository(), LoggingRepository.create());
  workers.push(db);

  return {
    db,
    async holdLock() {
      const release = await database.holdLock(LEADER_LOCK);
      if (release) {
        releases.push(release);
      }

      return release;
    },
  };
};

afterEach(async () => {
  await Promise.all(releases.splice(0).map((release) => release()));
  await Promise.all(workers.splice(0).map((db) => db.destroy()));
});

describe('holdLock', () => {
  it('lets only one worker hold the lock', async () => {
    await expect(startWorker().holdLock()).resolves.toBeInstanceOf(Function);
    await expect(startWorker().holdLock()).resolves.toBeUndefined();
  });

  it('keeps the lock when the pool resets its connections', async () => {
    const first = startWorker();
    await first.holdLock();

    await sql`SELECT pg_advisory_unlock_all()`.execute(first.db);

    await expect(startWorker().holdLock()).resolves.toBeUndefined();
  });

  it('frees the lock for another worker once released', async () => {
    const release = await startWorker().holdLock();

    await release!();

    await expect(startWorker().holdLock()).resolves.toBeInstanceOf(Function);
  });

  it('releases cleanly after the database terminates the lock connection', async () => {
    const closed = Promise.withResolvers<void>();
    const release = await startWorker(databaseName, closed.resolve).holdLock();
    const other = startWorker();

    await sql`
      SELECT pg_terminate_backend(pid)
      FROM pg_locks
      WHERE locktype = 'advisory'
        AND objid = hashtext(${LEADER_LOCK})::oid
    `.execute(other.db);

    await closed.promise;

    await expect(release!()).resolves.toBeUndefined();
    await expect(other.holdLock()).resolves.toBeInstanceOf(Function);
  });

  it('rejects when the database cannot be reached', async () => {
    await expect(startWorker('missing_database').holdLock()).rejects.toThrow(/does not exist/);
  });
});
