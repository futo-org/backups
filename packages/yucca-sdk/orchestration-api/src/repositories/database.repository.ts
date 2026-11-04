import { Injectable } from '@nestjs/common';
import { Kysely, sql } from 'kysely';
import { FileMigrationProvider, Migrator, NO_MIGRATIONS } from 'kysely/migration';
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

  async resetMigrations(): Promise<void> {
    const { error } = await this.createMigrator().migrateTo(NO_MIGRATIONS);

    if (error) {
      this.logger.error(`Migration rollback failed: ${error}`);
      throw new Error('Migration rollback failed.');
    }
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
