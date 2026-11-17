import { Injectable } from '@nestjs/common';
import { Kysely, sql, Transaction } from 'kysely';
import { FileMigrationProvider, Migrator } from 'kysely/migration';
import { InjectKysely } from 'nestjs-kysely';
import { join } from 'node:path';
import { MIGRATION_LOCK_TABLE, MIGRATION_TABLE, TABLE_PREFIX } from '../const.js';
import { DB } from '../schema/index.js';
import { LoggingRepository } from './logging.repository.js';
import { StorageRepository } from './storage.repository.js';

@Injectable()
export class DatabaseRepository {
  constructor(
    @InjectKysely('orchestrator') private db: Kysely<DB>,
    private readonly storage: StorageRepository,
    private readonly logger: LoggingRepository,
  ) {
    this.logger.setContext(DatabaseRepository.name);
  }

  holdLock(key: string): Promise<(() => Promise<void>) | undefined> {
    const acquired = Promise.withResolvers<(() => Promise<void>) | undefined>();
    const released = Promise.withResolvers<void>();

    const session = this.db.connection().execute(async (connection) => {
      const {
        rows: [{ locked, pid }],
      } = await sql<{
        locked: boolean;
        pid: number;
      }>`SELECT pg_try_advisory_lock(hashtext(${key})) AS locked, pg_backend_pid() AS pid`.execute(connection);

      if (!locked) {
        acquired.resolve(undefined);
        return;
      }

      acquired.resolve(() => {
        released.resolve();
        return settled;
      });

      await released.promise;

      const { rows } = await sql`SELECT 1 FROM pg_stat_activity WHERE pid = ${pid}`.execute(this.db);
      if (rows.length === 0) {
        return;
      }

      await sql`SELECT pg_advisory_unlock(hashtext(${key}))`.execute(connection);
    });

    const settled = session.catch((error: unknown) => {
      this.logger.warn('Advisory lock session failed', error);
      acquired.reject(error);
    });

    return acquired.promise;
  }

  withLock<R>(key: string, callback: (trx: Transaction<DB>) => Promise<R>): Promise<R> {
    return this.db.transaction().execute(async (trx) => {
      await sql`SELECT pg_advisory_xact_lock(hashtext(${key}))`.execute(trx);
      return callback(trx);
    });
  }

  async runMigrations(): Promise<void> {
    const {
      rows: [{ value }],
    } = await sql<{ value: unknown }>`SELECT 1::int8 AS value`.execute(this.db);
    if (typeof value !== 'number') {
      throw new TypeError('Misconfigured dialect: enable convertBigIntToNumber');
    }

    const { error, results } = await this.createMigrator().migrateToLatest();

    for (const result of results ?? []) {
      if (result.status === 'Success') {
        this.logger.debug(`Migration "${result.migrationName}" succeeded`);
      }

      if (result.status === 'Error') {
        this.logger.error(`Migration "${result.migrationName}" failed`);
      }
    }

    if (error) {
      this.logger.error(`Migrations failed: ${error}`);
      throw new Error('Migrations failed.');
    }

    this.logger.log('Finished running migrations');
  }

  async truncateTables(): Promise<void> {
    const { rows } = await sql<{ tablename: string }>`
      SELECT tablename FROM pg_tables
      WHERE schemaname = current_schema()
        AND starts_with(tablename, ${TABLE_PREFIX})
        AND tablename NOT IN (${MIGRATION_TABLE}, ${MIGRATION_LOCK_TABLE})`.execute(this.db);

    if (rows.length === 0) {
      return;
    }

    const tables = sql.join(rows.map(({ tablename }) => sql.table(tablename)));
    await sql`TRUNCATE ${tables}`.execute(this.db);
  }

  private createMigrator(): Migrator {
    return new Migrator({
      db: this.db,
      migrationLockTableName: MIGRATION_LOCK_TABLE,
      migrationTableName: MIGRATION_TABLE,
      provider: new FileMigrationProvider({
        fs: {
          readdir: this.storage.readdir,
        },
        path: { join },
        migrationFolder: join(import.meta.dirname, '..', 'schema/migrations'),
      }),
    });
  }
}
