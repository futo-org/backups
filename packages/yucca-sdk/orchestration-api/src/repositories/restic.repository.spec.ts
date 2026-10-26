import { jest } from '@jest/globals';
import { execFile } from 'node:child_process';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PassThrough } from 'node:stream';
import { promisify } from 'node:util';
import type { SupportLogLine } from '../utils/supportLogShipper.js';
import { SupportSession } from '../utils/supportSession.js';
import { ResticRepository } from './restic.repository.js';
import { SupportContextRepository } from './supportContext.repository.js';

const key = new Uint8Array(32).fill(7);
const placement = { siteCode: null, storageClusterCode: null };
const DAY = 24 * 60 * 60 * 1000;

describe(ResticRepository.name, () => {
  let dir: string;
  let repository: string;
  let source: string;
  let supportContext: SupportContextRepository;
  let restic: ResticRepository;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'yucca-restic-'));
    repository = join(dir, 'repository');
    source = join(dir, 'source');
    await mkdir(source);
    await writeFile(join(source, 'a.txt'), 'a');
    await writeFile(join(source, 'b.txt'), 'b');

    supportContext = new SupportContextRepository();
    const config = { getResticOptions: jest.fn(() => Promise.resolve({ connections: 2, packSizeMib: undefined })) };
    restic = new ResticRepository(
      config as never,
      { get: () => ({ cachePath: join(dir, 'cache') }) } as never,
      supportContext,
    );

    await restic.init(repository, key, placement);
  }, 30_000);

  const backupFromHost = (hostname: string, time = new Date()) =>
    promisify(execFile)(
      'restic',
      ['backup', '--no-cache', '--host', hostname, '--time', time.toISOString().slice(0, 19).replace('T', ' '), source],
      {
        env: {
          PATH: process.env.PATH,
          HOME: process.env.HOME,
          RESTIC_REPOSITORY: repository,
          RESTIC_PASSWORD: Buffer.from(key).toString('hex'),
        },
      },
    );

  const latestSnapshot = async () => {
    const snapshots = await restic.snapshots(repository, key, placement);
    return snapshots.toSorted((a, b) => +new Date(b.time) - +new Date(a.time))[0];
  };

  const recordedLines = async (operation: () => Promise<unknown>) => {
    const local = new PassThrough();
    const chunks: string[] = [];
    local.on('data', (chunk: Buffer) => chunks.push(chunk.toString('utf8')));
    const session = new SupportSession(local);

    await supportContext.run(session, operation);
    await session.finish();

    return chunks
      .join('')
      .split('\n')
      .filter(Boolean)
      .map((json) => JSON.parse(json) as SupportLogLine);
  };

  it('captures every file restic -vv reports during a backup in support mode', async () => {
    const lines = await recordedLines(() => restic.backup(repository, key, placement, [source]));

    const items = lines
      .filter(({ stream, command }) => stream === 'stdout' && command === 'backup')
      .map(({ message }) => JSON.parse(message) as { message_type: string; item?: string });

    expect(items.filter(({ message_type }) => message_type === 'verbose_status').map(({ item }) => item)).toEqual(
      expect.arrayContaining([join(source, 'a.txt'), join(source, 'b.txt')]),
    );
    expect(items.some(({ message_type }) => message_type === 'summary')).toBe(true);
  }, 30_000);

  it('reports per-file restore lines that only appear at verbosity 2', async () => {
    await restic.backup(repository, key, placement, [source]);
    const [snapshot] = await restic.snapshots(repository, key, placement);

    const lines = await recordedLines(() =>
      restic.restore(repository, key, placement, snapshot.id, { target: join(dir, 'target') }),
    );

    expect(lines.some(({ command, message }) => command === 'restore' && message.includes('"action":"restored"'))).toBe(
      true,
    );
  }, 30_000);

  it('keeps parsing JSON commands while verbose', async () => {
    await restic.backup(repository, key, placement, [source]);

    const lines = await recordedLines(async () => {
      await expect(restic.snapshots(repository, key, placement)).resolves.toHaveLength(1);
      await expect(restic.keyList(repository, key, placement)).resolves.toHaveLength(1);
      await expect(restic.stats(repository, key, placement)).resolves.toHaveProperty('snapshots_count', 1);
    });

    expect(new Set(lines.map(({ command }) => command))).toEqual(new Set(['snapshots', 'key list', 'stats']));
  }, 30_000);

  it('leaves restic quiet outside support mode', async () => {
    const attach = jest.spyOn(SupportSession.prototype, 'attach');

    await restic.backup(repository, key, placement, [source]);

    expect(attach).not.toHaveBeenCalled();
  }, 30_000);

  it('finds the parent snapshot after the hostname changes', async () => {
    await backupFromHost('previous-container');
    const previous = await latestSnapshot();

    await restic.backup(repository, key, placement, [source]);

    await expect(latestSnapshot()).resolves.toMatchObject({ parent: previous.id });
  }, 30_000);

  it('uses the parent snapshot it is given', async () => {
    await restic.backup(repository, key, placement, [source]);
    const first = await latestSnapshot();
    await restic.backup(repository, key, placement, [source]);

    await restic.backup(repository, key, placement, [source], undefined, undefined, [], first.id);

    await expect(latestSnapshot()).resolves.toMatchObject({ parent: first.id });
  }, 30_000);

  it('applies the retention policy across hostnames', async () => {
    await backupFromHost('previous-container', new Date(Date.now() - 100 * DAY));
    await restic.backup(repository, key, placement, [source]);

    await restic.forgetByPolicy(repository, key, placement, { keepWithin: '60d' });

    const snapshots = await restic.snapshots(repository, key, placement);
    expect(snapshots.map(({ hostname }) => hostname)).not.toContain('previous-container');
    expect(snapshots).toHaveLength(1);
  }, 30_000);

  it('stops a snapshot lookup when cancelled', async () => {
    const controller = new AbortController();
    controller.abort();

    await expect(restic.snapshot(repository, key, placement, 'latest', controller.signal)).rejects.toThrow();
  }, 30_000);
});
