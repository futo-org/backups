import {
  getMeta,
  getRepositories,
  listConnections,
  type MetaResponseDto,
} from '@futo-org/backups-api-client';
import type { PageLoad } from './$types';

const loadMeta = async (
  fetch: typeof globalThis.fetch,
): Promise<MetaResponseDto | undefined> => {
  try {
    return await getMeta({ fetch });
  } catch {
    return;
  }
};

export const load: PageLoad = async ({ fetch }) => {
  const [repositories, { connections }, meta] = await Promise.all([
    getRepositories({ fetch }),
    listConnections({ fetch }),
    loadMeta(fetch),
  ]);

  return {
    initialData: { repositories },
    connections,
    meta,
  };
};
