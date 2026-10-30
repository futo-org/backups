import { jest } from '@jest/globals';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createWriteStream } from 'node:fs';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { PassThrough, Writable } from 'node:stream';
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
    await expect(session.finish()).resolves.toEqual({ sessionId: undefined, droppedLines: 0, localDroppedLines: 0 });

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
    await expect(session.finish()).resolves.toEqual({
      sessionId: 'session-1',
      droppedLines: 3,
      localDroppedLines: 0,
    });

    expect(lines()[0].message).toBe('{"item":"/a"}');
    expect(pushed.map(({ message }) => message)).toEqual(['{"item":"<path>"}']);
    expect(shipper.finish).toHaveBeenCalled();
  });

  it('marks unchanged items from restic as expendable and every other line as essential', async () => {
    const pushed: [string, string, boolean][] = [];
    const shipper = {
      push: (line: SupportLogLine, { expendable = false }: { expendable?: boolean } = {}) =>
        pushed.push([line.stream, line.message, expendable]),
      finish: jest.fn(),
      droppedLines: 0,
    };
    const local = new PassThrough();
    collect(local);
    const session = new SupportSession(local, {
      sessionId: 'session-1',
      shipper: shipper as unknown as SupportLogShipper,
    });
    const unchanged = '{"message_type":"verbose_status","action":"unchanged","item":"/a"}';
    const modified = '{"message_type":"verbose_status","action":"modified","item":"/b"}';
    const summary = '{"message_type":"summary"}';

    await runChild(
      session,
      `console.log(${JSON.stringify([unchanged, modified, summary].join('\n'))}); console.error(${JSON.stringify(unchanged)});`,
    );
    await session.finish();

    expect(pushed).toHaveLength(4);
    expect(pushed).toEqual(
      expect.arrayContaining([
        ['stdout', unchanged, true],
        ['stdout', modified, false],
        ['stdout', summary, false],
        ['stderr', unchanged, false],
      ]),
    );
  });

  it('keeps recording when the local support log cannot be opened', async () => {
    const directory = await mkdtemp(`${tmpdir()}/yucca-support-`);
    const session = new SupportSession(createWriteStream(directory));

    await runChild(session, `console.log('line');`);

    await expect(session.finish()).resolves.toMatchObject({ localDroppedLines: 1 });
  });

  it('keeps recording when a write to the local support log fails', async () => {
    const failing = new Writable({ write: (_chunk, _encoding, done) => done(new Error('ENOSPC')) });
    const session = new SupportSession(failing);

    await runChild(session, `for (let i = 0; i < 5; i++) console.log('line ' + i);`);

    await expect(session.finish()).resolves.toMatchObject({ localDroppedLines: 5 });
  });

  it('drops local lines instead of queueing without bound behind a slow disk', async () => {
    const stuck = new Writable({ write: () => {} });
    const session = new SupportSession(stuck, undefined, { maxLocalBufferBytes: 1024, localFinishTimeoutMs: 100 });

    await runChild(session, `for (let i = 0; i < 1000; i++) console.log('x'.repeat(100));`);

    expect(stuck.writableLength).toBeLessThan(1024 + 300);
  });

  it('gives up on a stalled local support log at its deadline and counts what it never wrote', async () => {
    const stuck = new Writable({ write: () => {} });
    const session = new SupportSession(stuck, undefined, { localFinishTimeoutMs: 100 });

    await runChild(session, `for (let i = 0; i < 10; i++) console.log('line ' + i);`);
    const started = Date.now();
    const { localDroppedLines } = await session.finish();

    expect(Date.now() - started).toBeLessThan(2000);
    expect(localDroppedLines).toBeGreaterThanOrEqual(9);
  });

  it('counts every queued line that a failing disk discards', async () => {
    let calls = 0;
    const failing = new Writable({
      highWaterMark: 1,
      write: (_chunk, _encoding, done) => {
        calls++;
        setTimeout(() => done(new Error('EIO')), 20);
      },
    });
    const session = new SupportSession(failing);

    await runChild(session, `for (let i = 0; i < 20; i++) console.log('line ' + i);`);

    await expect(session.finish()).resolves.toMatchObject({ localDroppedLines: 20 });
    expect(calls).toBe(1);
  });
});
