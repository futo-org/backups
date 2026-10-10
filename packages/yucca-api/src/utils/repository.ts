import { RepositoryNotFoundException } from 'src/utils/exceptions.js';

/**
 * The caller's repository from a lookup that may have come back empty. An unknown id and another
 * user's id are the same 404, so the API does not reveal which repository ids exist.
 */
export const ensureOwned = <T extends { userId: string }>(repository: T | undefined, userId: string, id: string): T => {
  if (!repository || repository.userId !== userId) {
    throw new RepositoryNotFoundException(id);
  }

  return repository;
};
