import { TaskStatus } from '../enum.js';
import {
  explainMissingRestic,
  getTaskStatus,
  RESTIC_NOT_FOUND_MESSAGE,
  ResticNotFoundError,
  TaskWarningsError,
  writeError,
} from './errors.js';

const collectWrites = (error: unknown) => {
  const events: object[] = [];
  writeError((event) => events.push(event), error);
  return events;
};

describe('TaskWarningsError', () => {
  it('maps to the warn status', () => {
    expect(getTaskStatus(new TaskWarningsError([new Error('a')]))).toBe(TaskStatus.Warn);
  });

  it('writes one log event per collected error', () => {
    expect(collectWrites(new TaskWarningsError([new Error('first'), new Error('second')]))).toEqual([
      { message_type: 'error', error: { message: 'Error: first' } },
      { message_type: 'error', error: { message: 'Error: second' } },
    ]);
  });
});

const spawnError = (path: string) => Object.assign(new Error(`spawn ${path} ENOENT`), { code: 'ENOENT', path });

describe('explainMissingRestic', () => {
  it('turns a missing restic binary into a clear error', () => {
    expect(() => explainMissingRestic(spawnError('restic'))).toThrow(ResticNotFoundError);
  });

  it('records the clear message in the job log', () => {
    let error: unknown;
    try {
      explainMissingRestic(spawnError('restic'));
    } catch (error_) {
      error = error_;
    }

    expect(collectWrites(error)).toEqual([
      { message_type: 'error', error: { message: expect.stringContaining(RESTIC_NOT_FOUND_MESSAGE) } },
    ]);
    expect(JSON.stringify(collectWrites(error))).not.toContain('ENOENT');
  });

  it('rethrows other errors unchanged', () => {
    const other = spawnError('restic-proxy');
    expect(() => explainMissingRestic(other)).toThrow(other);
  });
});
