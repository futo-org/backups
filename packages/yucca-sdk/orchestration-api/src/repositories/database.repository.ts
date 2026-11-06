import { Injectable } from '@nestjs/common';
import { Kysely, sql, Transaction } from 'kysely';
import { FileMigrationProvider, Migrator } from 'kysely/migration';
import { InjectKysely } from 'nestjs-kysely';
import { join } from 'node:path';
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

  async tryLock(key: string): Promise<boolean> {
    const {
      rows: [{ locked }],
    } = await sql<{ locked: boolean }>`SELECT pg_try_advisory_lock(hashtext(${key})) AS locked`.execute(this.db);
    return locked;
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
        AND tablename LIKE 'futo\\_backups\\_%'
        AND tablename NOT IN ('futo_backups_kysely_migrations', 'futo_backups_kysely_migrations_lock')`.execute(
      this.db,
    );

    if (rows.length === 0) {
      return;
    }

    const tables = sql.join(rows.map(({ tablename }) => sql.table(tablename)));
    await sql`TRUNCATE ${tables}`.execute(this.db);
  }

  private createMigrator(): Migrator {
    return new Migrator({
      db: this.db,
      migrationLockTableName: 'futo_backups_kysely_migrations_lock',
      migrationTableName: 'futo_backups_kysely_migrations',
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
