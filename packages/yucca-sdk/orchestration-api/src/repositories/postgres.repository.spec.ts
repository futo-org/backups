import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PostgresRepository } from './postgres.repository.js';

describe(PostgresRepository.name, () => {
  let binDir: string;
  const postgres = new PostgresRepository();

  beforeEach(async () => {
    binDir = await mkdtemp(join(tmpdir(), 'postgres-repository-'));
    await writeFile(join(binDir, 'psql'), '#!/bin/sh\nexec sleep 30\n');
    await chmod(join(binDir, 'psql'), 0o755);
  });

  afterEach(async () => {
    await rm(binDir, { recursive: true, force: true });
  });

  it('writes the password only into the passfile', async () => {
    const passfile = join(binDir, '.pgpass');
    const client = await postgres.createClient(
      binDir,
      { host: 'database', port: 5432, user: 'postgres', password: "it's:secret", database: 'immich' },
      passfile,
    );

    expect(client.conninfo).not.toContain('secret');
    expect(await readFile(passfile, 'utf8')).toBe(String.raw`database:5432:*:postgres:it's\:secret` + '\n');
  });

  it('kills psql and rejects with the abort reason when cancelled', async () => {
    const controller = new AbortController();
    const reason = new Error('backup cancelled');
    const query = postgres.query({ binDir, conninfo: '' }, 'SELECT 1', {}, controller.signal);

    controller.abort(reason);

    await expect(query).rejects.toBe(reason);
  });
});
