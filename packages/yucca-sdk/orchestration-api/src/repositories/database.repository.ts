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

  async runMigrations(): Promise<{ ranInitialMigration: boolean }> {
    const migrator = this.createMigrator();
    const [initialMigration] = await migrator.getMigrations();
    const { error, results } = await migrator.migrateToLatest();

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

    const ranInitialMigration = (results ?? []).some(
      ({ migrationName, status }) => migrationName === initialMigration?.name && status === 'Success',
    );

    return { ranInitialMigration };
  }

  async resetMigrations(): Promise<void> {
    const { error } = await this.createMigrator().migrateTo(NO_MIGRATIONS);

    if (error) {
      this.logger.error(`Migration rollback failed: ${error}`);
      throw new Error('Migration rollback failed.');
    }
  }

  async restoreFrom(path: string): Promise<void> {
    await sql`PRAGMA foreign_keys = OFF`.execute(this.db);

    try {
      await sql`ATTACH DATABASE ${path} AS restored`.execute(this.db);

      const { rows: kyselyProbe } = await sql`
        SELECT name FROM restored.sqlite_master WHERE type = 'table' AND name = 'kysely_migrations'
      `.execute(this.db);

      if (kyselyProbe.length === 0) {
        await sql`DETACH DATABASE restored`.execute(this.db);
        throw new Error("Refusing to restore database, doesn't appear to be from the app");
      }

      await this.db.transaction().execute(async (trx) => {
        const currentSchema = await sql<{ name: string }>`
          SELECT name FROM main.sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        `.execute(trx);

        for (const { name } of currentSchema.rows) {
          await sql`DROP TABLE ${sql.table(name)}`.execute(trx);
        }

        const restoredSchema = await sql<{ type: string; name: string; sql: string }>`
          SELECT type, name, sql FROM restored.sqlite_master
          WHERE type IN ('table', 'index') AND name NOT LIKE 'sqlite_%' AND sql IS NOT NULL
          ORDER BY type = 'index'
        `.execute(trx);

        for (const object of restoredSchema.rows) {
          await sql.raw(object.sql).execute(trx);
        }

        for (const { name } of restoredSchema.rows.filter((object) => object.type === 'table')) {
          await sql`INSERT INTO ${sql.table(name)} SELECT * FROM ${sql.table(`restored.${name}`)}`.execute(trx);
        }
      });

      await sql`DETACH DATABASE restored`.execute(this.db);
    } finally {
      await sql`PRAGMA foreign_keys = ON`.execute(this.db);
    }

    await this.runMigrations();
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
