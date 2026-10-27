import { jest } from '@jest/globals';
import { createServer, type IncomingMessage, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { gunzipSync } from 'node:zlib';
import { SupportLogShipper, type SupportLogLine } from './supportLogShipper.js';

type Received = { headers: IncomingMessage['headers']; lines: SupportLogLine[] };

const line = (message: string): SupportLogLine => ({
  time: '2026-10-27T00:00:00.000Z',
  stream: 'stdout',
  command: 'backup',
  message,
});

const hourFromNow = () => new Date(Date.now() + 60 * 60 * 1000);

const until = async (condition: () => boolean) => {
  while (!condition()) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
};

describe(SupportLogShipper.name, () => {
  let server: Server;
  let url: string;
  let received: Received[];
  let respond: (request: IncomingMessage) => number;

  beforeEach(async () => {
    received = [];
    respond = () => 204;
    server = createServer((request, response) => {
      const chunks: Buffer[] = [];
      request.on('data', (chunk: Buffer) => chunks.push(chunk));
      request.on('end', () => {
        const status = respond(request);
        if (status === 204) {
          const body = gunzipSync(Buffer.concat(chunks)).toString('utf8');
          received.push({
            headers: request.headers,
            lines: body
              .split('\n')
              .filter(Boolean)
              .map((json) => JSON.parse(json) as SupportLogLine),
          });
        }
        response.writeHead(status).end();
      });
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    url = `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1/batches`;
  });

  afterEach(async () => {
    await new Promise((resolve) => server.close(resolve));
  });

  it('sends gzipped NDJSON batches in order and marks the last one final', async () => {
    const shipper = new SupportLogShipper(
      { url, credentials: { token: 'token-1', expiresAt: hourFromNow() }, refresh: jest.fn<() => Promise<never>>() },
      { batchBytes: 200, flushIntervalMs: 60_000 },
    );

    for (let index = 0; index < 10; index++) {
      shipper.push(line(`line ${index}`));
    }
    await shipper.finish();

    expect(received.flatMap(({ lines }) => lines.map(({ message }) => message))).toEqual(
      Array.from({ length: 10 }, (_, index) => `line ${index}`),
    );
    expect(received.map(({ headers }) => Number(headers['x-batch-seq']))).toEqual(received.map((_, index) => index));
    expect(received.at(-1)?.headers['x-batch-final']).toBe('true');
    expect(received.slice(0, -1).every(({ headers }) => headers['x-batch-final'] === undefined)).toBe(true);
    expect(received[0].headers).toMatchObject({
      authorization: 'Bearer token-1',
      'content-type': 'application/x-ndjson',
      'content-encoding': 'gzip',
    });
    expect(shipper.droppedLines).toBe(0);
  });

  it('keeps sending batches while the job runs, not only when it finishes', async () => {
    const shipper = new SupportLogShipper(
      { url, credentials: { token: 'token', expiresAt: hourFromNow() }, refresh: jest.fn<() => Promise<never>>() },
      { batchBytes: 50, flushIntervalMs: 60_000 },
    );
    const receivedMessages = () => received.flatMap(({ lines }) => lines.map(({ message }) => message));

    shipper.push(line('first batch'));
    await until(() => receivedMessages().includes('first batch'));
    shipper.push(line('second batch'));
    await until(() => receivedMessages().includes('second batch'));

    expect(received.every(({ headers }) => headers['x-batch-final'] === undefined)).toBe(true);
    await shipper.finish();
  });

  it('marks exactly one batch final when the remainder is still queued at finish', async () => {
    const shipper = new SupportLogShipper(
      { url, credentials: { token: 'token', expiresAt: hourFromNow() }, refresh: jest.fn<() => Promise<never>>() },
      { batchBytes: 100_000, flushIntervalMs: 60_000 },
    );

    shipper.push(line('only'));
    await shipper.finish();

    expect(received.filter(({ headers }) => headers['x-batch-final'] === 'true')).toHaveLength(1);
    expect(received.flatMap(({ lines }) => lines.map(({ message }) => message))).toEqual(['only']);
  });

  it('drops lines instead of buffering past its limit and reports how many', async () => {
    const shipper = new SupportLogShipper(
      { url, credentials: { token: 'token', expiresAt: hourFromNow() }, refresh: jest.fn<() => Promise<never>>() },
      { maxBufferBytes: 1000, batchBytes: 100_000, flushIntervalMs: 60_000 },
    );

    for (let index = 0; index < 100; index++) {
      shipper.push(line(`line ${index}`));
    }
    await shipper.finish();

    const sent = received.flatMap(({ lines }) => lines).length;
    expect(sent).toBeGreaterThan(0);
    expect(sent + shipper.droppedLines).toBe(100);
    expect(received.reduce((total, { headers }) => total + Number(headers['x-dropped-lines']), 0)).toBe(
      shipper.droppedLines,
    );
  });

  it('refreshes a rejected token and resends the batch', async () => {
    respond = (request) => (request.headers.authorization === 'Bearer stale' ? 401 : 204);
    const refresh = jest.fn(() => Promise.resolve({ token: 'fresh', expiresAt: hourFromNow() }));
    const shipper = new SupportLogShipper(
      { url, credentials: { token: 'stale', expiresAt: hourFromNow() }, refresh },
      { flushIntervalMs: 60_000 },
    );

    shipper.push(line('hello'));
    await shipper.finish();

    expect(refresh).toHaveBeenCalledTimes(1);
    expect(received.flatMap(({ lines }) => lines.map(({ message }) => message))).toEqual(['hello']);
  });

  it('stops streaming once the session can no longer be refreshed', async () => {
    const refresh = jest.fn(() => Promise.reject(new Error('Feature disabled')));
    const shipper = new SupportLogShipper(
      { url, credentials: { token: 'expired', expiresAt: new Date(0) }, refresh },
      { flushIntervalMs: 60_000 },
    );

    shipper.push(line('one'));
    await shipper.finish();
    shipper.push(line('two'));

    expect(received).toEqual([]);
    expect(shipper.droppedLines).toBe(2);
  });

  it('gives up on a batch the streamer refuses', async () => {
    respond = () => 413;
    const shipper = new SupportLogShipper(
      { url, credentials: { token: 'token', expiresAt: hourFromNow() }, refresh: jest.fn<() => Promise<never>>() },
      { flushIntervalMs: 60_000 },
    );

    shipper.push(line('too big'));
    await shipper.finish();

    expect(shipper.droppedLines).toBe(1);
  });

  it('stops the active send at its finish deadline and counts that batch as dropped', async () => {
    let requests = 0;
    const stalled = createServer(() => {
      requests++;
    });
    await new Promise<void>((resolve) => stalled.listen(0, '127.0.0.1', resolve));
    const stalledUrl = `http://127.0.0.1:${(stalled.address() as AddressInfo).port}/v1/batches`;

    try {
      const shipper = new SupportLogShipper(
        {
          url: stalledUrl,
          credentials: { token: 'token', expiresAt: hourFromNow() },
          refresh: jest.fn<() => Promise<never>>(),
        },
        { flushIntervalMs: 60_000, finishTimeoutMs: 200 },
      );

      for (const message of ['one', 'two']) {
        shipper.push(line(message));
      }
      const started = Date.now();
      await shipper.finish();
      const requestsAtFinish = requests;
      await new Promise((resolve) => setTimeout(resolve, 1500));

      expect(Date.now() - started).toBeLessThan(2000);
      expect(shipper.droppedLines).toBe(2);
      expect(requests).toBe(requestsAtFinish);
    } finally {
      stalled.closeAllConnections();
      await new Promise((resolve) => stalled.close(resolve));
    }
  });

  it('enforces its buffer limit in encoded bytes for multibyte lines', async () => {
    const shipper = new SupportLogShipper(
      { url, credentials: { token: 'token', expiresAt: hourFromNow() }, refresh: jest.fn<() => Promise<never>>() },
      { maxBufferBytes: 4096, batchBytes: 1_000_000, flushIntervalMs: 60_000 },
    );
    const message = '写真'.repeat(100);
    const encoded = Buffer.byteLength(JSON.stringify(line(message)), 'utf8') + 1;

    for (let index = 0; index < 20; index++) {
      shipper.push(line(message));
    }
    await shipper.finish();

    const sent = received.flatMap(({ lines }) => lines).length;
    expect(sent).toBe(Math.floor(4096 / encoded));
    expect(sent + shipper.droppedLines).toBe(20);
  });
});
