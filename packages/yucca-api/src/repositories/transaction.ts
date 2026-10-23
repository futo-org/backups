import { Kysely } from 'kysely';
import { DB } from 'src/schema/index.js';

const MAX_TRANSACTION_ATTEMPTS = 3;

export const inTransaction = async <T>(
  db: Kysely<DB>,
  operation: (transaction: Kysely<DB>) => Promise<T>,
  { retryDeadlocks = false }: { retryDeadlocks?: boolean } = {},
): Promise<T> => {
  if (db.isTransaction) {
    return operation(db);
  }

  for (let attempt = 1; ; attempt++) {
    try {
      return await db.transaction().execute(operation);
    } catch (error) {
      if (
        !retryDeadlocks ||
        !(error instanceof Error) ||
        !('code' in error) ||
        error.code !== '40P01' ||
        attempt >= MAX_TRANSACTION_ATTEMPTS
      ) {
        throw error;
      }
    }
  }
};
