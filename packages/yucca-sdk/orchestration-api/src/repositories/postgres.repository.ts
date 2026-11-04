import { Injectable } from '@nestjs/common';
import { type ChildProcess, spawn } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';

export type PostgresConnection = {
  host: string;
  port: number;
  user: string;
  password: string;
  database: string;
};

export type PostgresClient = {
  binDir: string;
  conninfo: string;
};

const quoteConninfoValue = (value: string | number) => `'${String(value).replaceAll(/['\\]/g, String.raw`\$&`)}'`;

const escapePassfileField = (value: string | number) => String(value).replaceAll(/[:\\]/g, String.raw`\$&`);

@Injectable()
export class PostgresRepository {
  async createClient(binDir: string, connection: PostgresConnection, passfile: string): Promise<PostgresClient> {
    const { host, port, user, password, database } = connection;
    await writeFile(
      passfile,
      `${[host, port, '*', user, password].map((field) => escapePassfileField(field)).join(':')}\n`,
      {
        mode: 0o600,
      },
    );

    const conninfo = Object.entries({ host, port, user, dbname: database, passfile })
      .map(([key, value]) => `${key}=${quoteConninfoValue(value)}`)
      .join(' ');

    return { binDir, conninfo };
  }

  async query(client: PostgresClient, sql: string, variables: Record<string, string> = {}): Promise<string[][]> {
    const args = ['-X', '-q', '-A', '-t', '-F', '\t', '-v', 'ON_ERROR_STOP=1', '-d', client.conninfo, '-f', '-'];
    for (const [name, value] of Object.entries(variables)) {
      args.push('-v', `${name}=${value}`);
    }

    const psql = spawn(join(client.binDir, 'psql'), args, { stdio: ['pipe', 'pipe', 'pipe'] });
    const stdout = await this.collect(psql, sql);

    return stdout
      .split('\n')
      .filter((line) => line.length > 0)
      .map((line) => line.split('\t'));
  }

  receiveWal(client: PostgresClient, directory: string, slot: string): ChildProcess {
    return spawn(
      join(client.binDir, 'pg_receivewal'),
      ['-d', client.conninfo, '-D', directory, '--slot', slot, '--no-loop', '--synchronous', '--status-interval', '10'],
      { stdio: ['ignore', 'ignore', 'pipe'] },
    );
  }

  baseBackupCommand(client: PostgresClient): string[] {
    return [
      join(client.binDir, 'pg_basebackup'),
      '-d',
      client.conninfo,
      '--format=tar',
      '--pgdata=-',
      '--wal-method=none',
      '--checkpoint=fast',
    ];
  }

  private collect(child: ChildProcess, input: string): Promise<string> {
    return new Promise((resolve, reject) => {
      let stdout = '';
      let stderr = '';
      child.stdout?.on('data', (data) => (stdout += data));
      child.stderr?.on('data', (data) => (stderr += data));
      child.once('error', reject);
      child.once('close', (code) =>
        code === 0 ? resolve(stdout) : reject(new Error(`psql exited with ${code}: ${stderr.trim()}`)),
      );
      child.stdin?.end(input);
    });
  }
}
