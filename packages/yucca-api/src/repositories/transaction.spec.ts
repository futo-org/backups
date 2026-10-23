import { jest } from '@jest/globals';
import { Kysely } from 'kysely';
import { inTransaction } from 'src/repositories/transaction.js';
import { DB } from 'src/schema/index.js';

type Operation = (transaction: Kysely<DB>) => Promise<string>;

const newMocks = () => {
  const transactions: Kysely<DB>[] = [];
  const execute = jest.fn<(operation: Operation) => Promise<string>>().mockImplementation((operation) => {
    const transaction = { isTransaction: true } as never;
    transactions.push(transaction);
    return operation(transaction);
  });
  const transaction = jest.fn(() => ({ execute }));
  return { db: { isTransaction: false, transaction } as never, transaction, transactions };
};

const deadlock = () => Object.assign(new Error('deadlock detected'), { code: '40P01' });

describe(inTransaction.name, () => {
  it('leaves deadlock recovery disabled unless requested', async () => {
    const mocks = newMocks();
    const error = deadlock();
    const operation = jest.fn<Operation>().mockRejectedValue(error);

    await expect(inTransaction(mocks.db, operation)).rejects.toBe(error);

    expect(operation).toHaveBeenCalledTimes(1);
    expect(mocks.transaction).toHaveBeenCalledTimes(1);
  });

  it('stops after three deadlocks and preserves the last database error', async () => {
    const mocks = newMocks();
    const error = deadlock();
    const operation = jest
      .fn<Operation>()
      .mockRejectedValueOnce(deadlock())
      .mockRejectedValueOnce(deadlock())
      .mockRejectedValue(error);

    await expect(inTransaction(mocks.db, operation, { retryDeadlocks: true })).rejects.toBe(error);

    expect(operation).toHaveBeenCalledTimes(3);
    expect(mocks.transaction).toHaveBeenCalledTimes(3);
  });

  it.each([
    { name: 'constraint violation', error: Object.assign(new Error('duplicate key'), { code: '23505' }) },
    { name: 'uncoded database failure', error: new Error('connection closed') },
    { name: 'non-error rejection', error: { code: '40P01' } },
  ])('propagates a $name without retrying', async ({ error }) => {
    const mocks = newMocks();
    const operation = jest.fn<Operation>().mockRejectedValue(error);

    await expect(inTransaction(mocks.db, operation, { retryDeadlocks: true })).rejects.toBe(error);

    expect(operation).toHaveBeenCalledTimes(1);
    expect(mocks.transaction).toHaveBeenCalledTimes(1);
  });

  it('leaves retrying an inherited transaction to its owner', async () => {
    const mocks = newMocks();
    const transaction = { isTransaction: true, transaction: mocks.transaction } as never;
    const error = deadlock();
    const operation = jest.fn<Operation>().mockRejectedValue(error);

    await expect(inTransaction(transaction, operation, { retryDeadlocks: true })).rejects.toBe(error);

    expect(operation).toHaveBeenCalledTimes(1);
    expect(operation).toHaveBeenCalledWith(transaction);
    expect(mocks.transaction).not.toHaveBeenCalled();
  });

  it('retries the entire operation in a fresh transaction and returns its result', async () => {
    const mocks = newMocks();
    const operation = jest.fn<Operation>().mockRejectedValueOnce(deadlock()).mockResolvedValue('linked');

    await expect(inTransaction(mocks.db, operation, { retryDeadlocks: true })).resolves.toBe('linked');

    expect(operation).toHaveBeenCalledTimes(2);
    expect(mocks.transaction).toHaveBeenCalledTimes(2);
    expect(operation).toHaveBeenNthCalledWith(1, mocks.transactions[0]);
    expect(operation).toHaveBeenNthCalledWith(2, mocks.transactions[1]);
    expect(mocks.transactions[1]).not.toBe(mocks.transactions[0]);
  });
});
