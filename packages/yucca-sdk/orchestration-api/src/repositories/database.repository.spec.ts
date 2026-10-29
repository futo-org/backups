import { PGLiteSocketServer } from '@electric-sql/pglite-socket';
import { schemaDiff, schemaFromCode, schemaFromDatabase } from '@immich/sql-tools';
import { Kysely, sql } from 'kysely';
import { PGliteDialect } from 'kysely-pglite-dialect';
import { createPGlite } from '../bin/pglite.js';
import '../schema/index.js';
import type { DB } from '../schema/index.js';
import { DatabaseRepository } from './database.repository.js';
import { LoggingRepository } from './logging.repository.js';
import { StorageRepository } from './storage.repository.js';

describe(DatabaseRepository.name, () => {
  let db: Kysely<DB>;
  let server: PGLiteSocketServer;
  let repository: DatabaseRepository;

  const tableNames = async () => {
    const tables = await db.introspection.getTables();
    return tables.map(({ name }) => name).toSorted();
  };

  const enumNames = async () => {
    const { rows } = await sql<{ name: string }>`SELECT typname AS name FROM pg_type WHERE typtype = 'e'`.execute(db);
    return rows.map(({ name }) => name).toSorted();
  };

  beforeAll(async () => {
    const database = await createPGlite();
    server = new PGLiteSocketServer({ db: database, host: '127.0.0.1', port: 0 });
    await server.start();
    db = new Kysely<DB>({ dialect: new PGliteDialect(database) });
    repository = new DatabaseRepository(db, new StorageRepository(), LoggingRepository.create());
  });

  afterAll(async () => {
    await db?.destroy();
    await server?.stop();
  });

  it('migrates to the schema in code using only prefixed tables and types', async () => {
    await repository.runMigrations();

    const tables = await tableNames();
    expect(tables).toContain('futo_backups_kysely_migrations');
    expect(tables.every((name) => name.startsWith('futo_backups_'))).toBe(true);
    const enums = await enumNames();
    expect(enums.every((name) => name.startsWith('futo_backups_'))).toBe(true);

    const migrated = await schemaFromDatabase({
      connection: { connectionType: 'url', url: `postgresql://postgres@${server.getServerConn()}/postgres` },
    });
    const drift = schemaDiff(schemaFromCode({ overrides: false, namingStrategy: 'default' }), migrated, {
      tables: { ignoreExtra: true },
      parameters: { ignoreExtra: true },
      extensions: { ignoreExtra: true },
    });
    expect(drift.asSql()).toEqual([]);
  });

  it('rolls every migration back and applies them again', async () => {
    await repository.runMigrations();
    const migratedTables = await tableNames();

    await repository.resetMigrations();
    expect(await tableNames()).toEqual(['futo_backups_kysely_migrations', 'futo_backups_kysely_migrations_lock']);
    expect(await enumNames()).toEqual([]);

    await repository.runMigrations();
    expect(await tableNames()).toEqual(migratedTables);
  });
});
