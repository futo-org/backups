import { jest } from '@jest/globals';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PassThrough } from 'node:stream';
import type { SupportLogLine } from '../utils/supportLogShipper.js';
import { SupportSession } from '../utils/supportSession.js';
import { ResticRepository } from './restic.repository.js';
import { SupportContextRepository } from './supportContext.repository.js';

const key = new Uint8Array(32).fill(7);
const placement = { siteCode: null, storageClusterCode: null };

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
});
