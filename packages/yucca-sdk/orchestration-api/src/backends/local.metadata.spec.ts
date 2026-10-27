import { mkdtemp, readdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LOCAL_METADATA_FILE_NAME, LocalMetadata } from './local.metadata.js';

describe(LocalMetadata.name, () => {
  let directory: string;
  let metadataPath: string;

  const storedContent = async () => JSON.parse(await readFile(metadataPath, 'utf8')) as unknown;

  beforeEach(async () => {
    directory = await mkdtemp(join(tmpdir(), 'yucca-local-metadata-'));
    metadataPath = join(directory, LOCAL_METADATA_FILE_NAME);
  });

  afterEach(async () => {
    await rm(directory, { recursive: true, force: true });
  });

  it('reads nothing from a directory without metadata', async () => {
    await expect(new LocalMetadata(directory).read()).resolves.toEqual({});
  });

  it('reads back what another instance stored', async () => {
    await new LocalMetadata(directory).update({ name: 'Immich' });

    await expect(new LocalMetadata(directory).read()).resolves.toEqual({ name: 'Immich' });
  });

  it('keeps stored fields an update does not change, including ones it does not know', async () => {
    await writeFile(metadataPath, JSON.stringify({ name: 'Immich', addedLater: { enabled: true } }));

    await new LocalMetadata(directory).update({ name: 'Family Photos' });

    await expect(storedContent()).resolves.toEqual({ name: 'Family Photos', addedLater: { enabled: true } });
  });

  it('ignores a field of the wrong type', async () => {
    await writeFile(metadataPath, JSON.stringify({ name: 42 }));

    await expect(new LocalMetadata(directory).read()).resolves.toEqual({});
  });

  it.each(['{', 'null', '[]', '"Immich"'])('treats unreadable content %s as empty', async (content) => {
    await writeFile(metadataPath, content);
    const metadata = new LocalMetadata(directory);

    await expect(metadata.read()).resolves.toEqual({});

    await metadata.update({ name: 'Immich' });

    await expect(storedContent()).resolves.toEqual({ name: 'Immich' });
  });

  it('replaces a symlinked file instead of writing through it', async () => {
    const target = join(directory, 'outside.txt');
    await writeFile(target, 'untouched');
    await symlink(target, metadataPath);

    await new LocalMetadata(directory).update({ name: 'Immich' });

    await expect(readFile(target, 'utf8')).resolves.toBe('untouched');
    await expect(new LocalMetadata(directory).read()).resolves.toEqual({ name: 'Immich' });
    await expect(readdir(directory)).resolves.toEqual([LOCAL_METADATA_FILE_NAME, 'outside.txt']);
  });

  it('fails to update a directory that does not exist', async () => {
    await expect(new LocalMetadata(join(directory, 'missing')).update({ name: 'Immich' })).rejects.toThrow();
    await expect(readdir(directory)).resolves.toEqual([]);
  });
});
