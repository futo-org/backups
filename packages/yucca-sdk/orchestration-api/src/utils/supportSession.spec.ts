import { jest } from '@jest/globals';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { PassThrough } from 'node:stream';
import type { SupportLogLine, SupportLogShipper } from './supportLogShipper.js';
import { SupportSession } from './supportSession.js';

const collect = (stream: PassThrough) => {
  const chunks: string[] = [];
  stream.on('data', (chunk: Buffer) => chunks.push(chunk.toString('utf8')));
  return () =>
    chunks
      .join('')
      .split('\n')
      .filter(Boolean)
      .map((json) => JSON.parse(json) as SupportLogLine);
};

const runChild = async (session: SupportSession, script: string) => {
  const child = spawn(process.execPath, ['-e', script]);
  session.attach(child, 'backup');
  await once(child, 'close');
};

describe(SupportSession.name, () => {
  it('records every stdout and stderr line locally', async () => {
    const local = new PassThrough();
    const lines = collect(local);
    const session = new SupportSession(local);

    await runChild(session, `console.log('{"item":"/a"}'); console.error('retrying'); console.log('done');`);
    await expect(session.finish()).resolves.toEqual({ sessionId: undefined, droppedLines: 0 });

    expect(lines().map(({ stream, command, message }) => [stream, command, message])).toEqual(
      expect.arrayContaining([
        ['stdout', 'backup', '{"item":"/a"}'],
        ['stderr', 'backup', 'retrying'],
        ['stdout', 'backup', 'done'],
      ]),
    );
  });

  it('streams redacted lines while keeping the local copy intact', async () => {
    const local = new PassThrough();
    const lines = collect(local);
    const pushed: SupportLogLine[] = [];
    const shipper = { push: (line: SupportLogLine) => pushed.push(line), finish: jest.fn(), droppedLines: 3 };
    const session = new SupportSession(local, {
      sessionId: 'session-1',
      shipper: shipper as unknown as SupportLogShipper,
      redact: (line) => line.replace('/a', '<path>'),
    });

    await runChild(session, `console.log('{"item":"/a"}');`);
    await expect(session.finish()).resolves.toEqual({ sessionId: 'session-1', droppedLines: 3 });

    expect(lines()[0].message).toBe('{"item":"/a"}');
    expect(pushed.map(({ message }) => message)).toEqual(['{"item":"<path>"}']);
    expect(shipper.finish).toHaveBeenCalled();
  });
});
