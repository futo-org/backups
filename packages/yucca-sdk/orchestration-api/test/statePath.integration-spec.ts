import { jest } from '@jest/globals';
import { Logger } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BackendType, ConfigurationKey } from '../src/enum.js';
import { bootConfig } from './testUtils.js';

function messages(spy: jest.SpyInstance): string[] {
  return spy.mock.calls.map(([message]) => String(message));
}

let statePath: string;
let warn: jest.SpyInstance;

beforeEach(async () => {
  statePath = await mkdtemp(join(tmpdir(), 'yucca-state-'));
  warn = jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => {});
  jest.spyOn(Logger.prototype, 'log').mockImplementation(() => {});
});

afterEach(() => {
  jest.restoreAllMocks();
});

describe('State location', () => {
  it('warns loudly when it generates a master encryption key', async () => {
    const first = await bootConfig(statePath);
    await first.config.bootstrap();
    const key = await first.config.getMasterEncryptionKey();
    await first.close();

    expect(messages(warn).join('\n')).toMatch(/master encryption key/i);
    expect(messages(warn).join('\n')).toContain(statePath);

    warn.mockClear();

    const second = await bootConfig(statePath);
    await second.config.bootstrap();

    await expect(second.config.getMasterEncryptionKey()).resolves.toEqual(key);
    expect(warn).not.toHaveBeenCalled();

    await second.close();
  });

  it('warns when the state database is opened from a different path than it was created at', async () => {
    const first = await bootConfig(statePath);
    await first.config.bootstrap();
    await first.close();

    const movedPath = await mkdtemp(join(tmpdir(), 'yucca-state-moved-'));
    warn.mockClear();

    const second = await bootConfig(movedPath, join(statePath, 'pglite'));
    await second.config.bootstrap();
    await second.close();

    const warnings = messages(warn).join('\n');
    expect(warnings).toContain(statePath);
    expect(warnings).toContain(movedPath);
  });

  it('refuses to generate a new master encryption key when repositories already exist', async () => {
    const first = await bootConfig(statePath);
    await first.config.bootstrap();
    const backendId = randomUUID();
    await first.db
      .insertInto('futo_backups_backends')
      .values({ id: backendId, configuration: { type: BackendType.Local, path: statePath } })
      .execute();
    await first.db
      .insertInto('futo_backups_repositories')
      .values({ id: randomUUID(), remoteId: 'remote', backendId })
      .execute();
    await first.db.deleteFrom('futo_backups_config').where('key', '=', ConfigurationKey.EncryptionKey).execute();
    await first.close();

    const second = await bootConfig(statePath);

    await expect(second.config.bootstrap()).rejects.toThrow(/encryption key/i);
    await expect(second.config.hasEncryptionKey()).resolves.toBe(false);

    await second.close();
  });
});
