import { TaskStatus } from '../enum.js';
import { getTaskStatus, TaskWarningsError, writeError } from './errors.js';

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
