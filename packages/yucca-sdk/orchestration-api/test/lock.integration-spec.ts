import { createPostgres } from '@immich/sql-tools';
import { Kysely, sql } from 'kysely';
import { PostgresJSDialect } from 'kysely-postgres-js';
import { randomUUID } from 'node:crypto';
import { DatabaseRepository } from '../src/repositories/database.repository.js';
import { LoggingRepository } from '../src/repositories/logging.repository.js';
import { StorageRepository } from '../src/repositories/storage.repository.js';
import type { DB } from '../src/schema/index.js';

const connectTo = (database: string) => {
  const dialect = new PostgresJSDialect({
    postgres: createPostgres({
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
let databaseName: string;

const startWorker = () => {
  const db = connectTo(databaseName);
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

beforeAll(async () => {
  databaseName = `orchestrator_lock_${randomUUID().replaceAll('-', '')}`;
  const server = connectTo(process.env.POSTGRES_DATABASE ?? 'yucca');
  await sql`CREATE DATABASE ${sql.id(databaseName)}`.execute(server);
  await server.destroy();
});

afterEach(async () => {
  await Promise.all(releases.splice(0).map((release) => release()));
  await Promise.all(workers.splice(0).map((db) => db.destroy()));
});

afterAll(async () => {
  const server = connectTo(process.env.POSTGRES_DATABASE ?? 'yucca');
  await sql`DROP DATABASE IF EXISTS ${sql.id(databaseName)} WITH (FORCE)`.execute(server);
  await server.destroy();
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
});
