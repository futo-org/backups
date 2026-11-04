import { Kysely, sql } from 'kysely';
import { existsSync } from 'node:fs';
import { chmod, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createPGliteDatabase } from './pglite.js';

let directory: string;
let db: Kysely<{ notes: { text: string } }>;
let databaseHooks: Awaited<ReturnType<typeof createPGliteDatabase>>['databaseHooks'];

const notes = async () => {
  const rows = await db.selectFrom('notes').select('text').orderBy('text').execute();
  return rows.map(({ text }) => text);
};

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'pglite-hooks-'));
  await mkdir(join(directory, 'data'));
  const database = await createPGliteDatabase(join(directory, 'data', 'state-pglite'), directory);
  databaseHooks = database.databaseHooks;
  db = new Kysely({ dialect: database.dialect });
  await sql`CREATE TABLE notes (text text NOT NULL)`.execute(db);
  await db.insertInto('notes').values({ text: 'dumped' }).execute();
}, 30_000);

afterEach(async () => {
  await chmod(join(directory, 'data'), 0o755);
  await db.destroy();
  await rm(directory, { recursive: true, force: true });
});

describe(createPGliteDatabase.name, () => {
  it('replaces the live database with a dump', async () => {
    const fileName = await databaseHooks.dump(new AbortController().signal);
    await db.insertInto('notes').values({ text: 'after dump' }).execute();

    await databaseHooks.restore(fileName);

    await expect(notes()).resolves.toEqual(['dumped']);
    expect(existsSync(join(directory, fileName))).toBe(false);
  }, 30_000);

  it('removes the dump once the backup has taken it', async () => {
    const fileName = await databaseHooks.dump(new AbortController().signal);

    await databaseHooks.cleanup!();

    expect(existsSync(join(directory, fileName))).toBe(false);
  }, 30_000);

  it('keeps the live database when the dump cannot be loaded', async () => {
    await writeFile(join(directory, 'broken.dump'), 'not a dump');

    await expect(databaseHooks.restore('broken.dump')).rejects.toThrow();

    await expect(notes()).resolves.toEqual(['dumped']);
  }, 30_000);

  it('keeps the live database when the dump cannot be staged beside it', async () => {
    const fileName = await databaseHooks.dump(new AbortController().signal);
    await db.insertInto('notes').values({ text: 'after dump' }).execute();
    await chmod(join(directory, 'data'), 0o555);

    await expect(databaseHooks.restore(fileName)).rejects.toThrow();

    await expect(notes()).resolves.toEqual(['after dump', 'dumped']);
  }, 30_000);
});
