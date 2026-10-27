import { mkdir, mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BackendType } from '../enum.js';
import { LocalBackend } from './local.backend.js';

describe(LocalBackend.name, () => {
  let path: string;
  let backend: LocalBackend;

  const namesOf = async (from: LocalBackend) => {
    const { repositories } = await from.getRepositories();
    return Object.fromEntries(repositories.map(({ id, name }) => [id, name]));
  };

  beforeEach(async () => {
    path = await mkdtemp(join(tmpdir(), 'yucca-local-backend-'));
    backend = new LocalBackend({ type: BackendType.Local, path });
  });

  afterEach(async () => {
    await rm(path, { recursive: true, force: true });
  });

  it('lists a repository under the name it was created with', async () => {
    const { repository } = await backend.createRepository({ name: 'Immich', worm: false });

    await expect(namesOf(backend)).resolves.toEqual({ [repository.id]: 'Immich' });
  });

  it('keeps the name for another installation pointed at the same path', async () => {
    const { repository } = await backend.createRepository({ name: 'Immich', worm: false });

    const freshInstall = new LocalBackend({ type: BackendType.Local, path });

    await expect(namesOf(freshInstall)).resolves.toEqual({ [repository.id]: 'Immich' });
    await expect(freshInstall.getRepository(repository.id)).resolves.toEqual({
      repository: expect.objectContaining({ id: repository.id, name: 'Immich' }),
    });
  });

  it('persists a rename', async () => {
    const { repository } = await backend.createRepository({ name: 'Immich', worm: false });

    await expect(backend.updateRepository(repository.id, { name: 'Family Photos' })).resolves.toEqual({
      repository: expect.objectContaining({ name: 'Family Photos' }),
    });
    await expect(namesOf(backend)).resolves.toEqual({ [repository.id]: 'Family Photos' });
  });

  it('keeps the stored name when an update does not change it', async () => {
    const { repository } = await backend.createRepository({ name: 'Immich', worm: false });

    await expect(backend.updateRepository(repository.id, { worm: false })).resolves.toEqual({
      repository: expect.objectContaining({ name: 'Immich' }),
    });
  });

  it('names a repository without stored metadata Unknown', async () => {
    await mkdir(join(path, 'legacy-repository'));
    await writeFile(join(path, 'not-a-repository'), '');

    await expect(namesOf(backend)).resolves.toEqual({ 'legacy-repository': 'Unknown' });
  });

  it('names a repository whose metadata has no usable name Unknown', async () => {
    await mkdir(join(path, 'corrupt-repository'));
    await writeFile(join(path, 'corrupt-repository', 'futo-backups.json'), '{"name":42}');

    await expect(namesOf(backend)).resolves.toEqual({ 'corrupt-repository': 'Unknown' });
    await expect(backend.getRepository('corrupt-repository')).resolves.toEqual({
      repository: expect.objectContaining({ name: 'Unknown' }),
    });
  });

  it('rejects a repository that does not exist', async () => {
    await expect(backend.getRepository('missing')).rejects.toThrow();
    await expect(backend.updateRepository('missing', { name: 'Immich' })).rejects.toThrow();
    await expect(readdir(path)).resolves.toEqual([]);
  });

  it('rejects repository ids outside the backend path', async () => {
    await expect(backend.updateRepository('../escaped', { name: 'Immich' })).rejects.toThrow(
      'Invalid repository id ../escaped',
    );
    await expect(backend.getResticEndpoint('.')).rejects.toThrow('Invalid repository id .');
  });
});
