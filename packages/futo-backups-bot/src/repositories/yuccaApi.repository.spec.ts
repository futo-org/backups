import { jest } from '@jest/globals';
import { env } from 'src/env.js';
import { YuccaApiRepository } from './yuccaApi.repository.js';

const batch = {
  id: 'batch-1',
  guildId: 'guild-1',
  channelId: 'channel-1',
  messageId: 'message-1',
  maxClaims: 5,
  remaining: 2,
  cancelledAt: null,
  createdByDiscordUserId: 'staff-1',
};

describe(YuccaApiRepository.name, () => {
  let sut: YuccaApiRepository;
  let mocks: { fetch: jest.SpiedFunction<typeof fetch>; originalUrl: string; originalSecret: string };

  beforeEach(() => {
    mocks = {
      fetch: jest.spyOn(globalThis, 'fetch'),
      originalUrl: env.YUCCA_API_URL,
      originalSecret: env.INTERNAL_SECRET,
    };
    env.YUCCA_API_URL = 'http://yucca.test';
    env.INTERNAL_SECRET = 'test-internal-secret';
    sut = new YuccaApiRepository();
  });

  afterEach(() => {
    env.YUCCA_API_URL = mocks.originalUrl;
    env.INTERNAL_SECRET = mocks.originalSecret;
    jest.restoreAllMocks();
  });

  it('reads authoritative drop availability with the internal secret and encoded id', async () => {
    mocks.fetch.mockResolvedValue(Response.json(batch));

    await expect(sut.getInviteBatch('batch/1')).resolves.toEqual(batch);

    expect(mocks.fetch).toHaveBeenCalledWith(
      new URL('http://yucca.test/api/internal/discord/invite-batches/batch%2F1'),
      expect.objectContaining({
        method: 'GET',
        headers: { 'Content-Type': 'application/json', 'X-Internal-Secret': 'test-internal-secret' },
        signal: expect.any(AbortSignal),
      }),
    );
  });

  it('lists posted drops and parses cancellation timestamps', async () => {
    const cancelledAt = '2026-10-22T12:00:00.000Z';
    mocks.fetch.mockResolvedValue(Response.json({ items: [{ ...batch, cancelledAt }] }));

    await expect(sut.listInviteBatches()).resolves.toEqual([{ ...batch, cancelledAt: new Date(cancelledAt) }]);

    expect(mocks.fetch).toHaveBeenCalledWith(
      new URL('http://yucca.test/api/internal/discord/invite-batches'),
      expect.objectContaining({ method: 'GET', signal: expect.any(AbortSignal) }),
    );
  });

  it('bounds message-id persistence so a stalled PATCH can reject and be retried', async () => {
    const controller = new AbortController();
    const timeout = jest.spyOn(AbortSignal, 'timeout').mockReturnValue(controller.signal);
    mocks.fetch.mockImplementationOnce(
      (_url, options) =>
        new Promise<Response>((_resolve, reject) => {
          options!.signal!.addEventListener('abort', () => reject(options!.signal!.reason as Error), { once: true });
        }),
    );
    const pending = sut.setInviteBatchMessage('batch/1', 'message-1');
    expect(timeout).toHaveBeenCalledWith(10_000);
    controller.abort(new DOMException('Persistence timed out', 'TimeoutError'));

    await expect(pending).rejects.toThrow('Persistence timed out');

    expect(mocks.fetch).toHaveBeenCalledWith(
      new URL('http://yucca.test/api/internal/discord/invite-batches/batch%2F1/message'),
      expect.objectContaining({
        method: 'PATCH',
        body: JSON.stringify({ messageId: 'message-1' }),
        signal: controller.signal,
      }),
    );
    mocks.fetch.mockResolvedValue(new Response(null, { status: 204 }));
    await expect(sut.setInviteBatchMessage('batch/1', 'message-1')).resolves.toBeUndefined();
  });

  it('returns null for unknown drops', async () => {
    mocks.fetch.mockResolvedValue(new Response(null, { status: 404 }));

    await expect(sut.getInviteBatch('missing')).resolves.toBeNull();
  });

  it('rejects failed availability requests rather than treating them as exhaustion', async () => {
    mocks.fetch.mockImplementation(() => Promise.resolve(new Response('unavailable', { status: 503 })));

    await expect(sut.getInviteBatch('batch-1')).rejects.toThrow('failed: 503');
    await expect(sut.listInviteBatches()).rejects.toThrow('failed: 503');
  });

  it('rejects invalid availability counts', async () => {
    mocks.fetch.mockResolvedValue(Response.json({ ...batch, remaining: -1 }));

    await expect(sut.getInviteBatch('batch-1')).rejects.toThrow();
  });

  it('turns support mode on for a ticket owner', async () => {
    mocks.fetch.mockResolvedValue(Response.json({ status: 'enabled' }));

    await expect(sut.enableSupportMode('thread/1', 'customer-1')).resolves.toBe('enabled');

    expect(mocks.fetch).toHaveBeenCalledWith(
      new URL('http://yucca.test/api/internal/discord/support-mode/thread%2F1'),
      expect.objectContaining({
        method: 'PUT',
        body: JSON.stringify({ discordUserId: 'customer-1' }),
        signal: expect.any(AbortSignal),
      }),
    );
  });

  it('reports a ticket owner without a linked account', async () => {
    mocks.fetch.mockResolvedValue(new Response(null, { status: 404 }));

    await expect(sut.enableSupportMode('thread-1', 'stranger')).resolves.toBe('no-account');
  });

  it('lists the tickets holding support mode', async () => {
    mocks.fetch.mockResolvedValue(Response.json({ items: [{ threadId: 'thread-1' }] }));

    await expect(sut.listSupportModeTickets()).resolves.toEqual(['thread-1']);
    expect(mocks.fetch).toHaveBeenCalledWith(
      new URL('http://yucca.test/api/internal/discord/support-mode'),
      expect.objectContaining({ method: 'GET', signal: expect.any(AbortSignal) }),
    );
  });

  it('turns support mode off for a closed ticket', async () => {
    mocks.fetch.mockResolvedValue(new Response(null, { status: 204 }));

    await sut.disableSupportMode('thread-1');

    expect(mocks.fetch).toHaveBeenCalledWith(
      new URL('http://yucca.test/api/internal/discord/support-mode/thread-1'),
      expect.objectContaining({ method: 'DELETE', signal: expect.any(AbortSignal) }),
    );
  });

  it.each([
    ['turning support mode on', (sut: YuccaApiRepository) => sut.enableSupportMode('thread-1', 'customer-1')],
    ['listing support-mode tickets', (sut: YuccaApiRepository) => sut.listSupportModeTickets()],
    ['turning support mode off', (sut: YuccaApiRepository) => sut.disableSupportMode('thread-1')],
  ])('gives up %s when yucca-api never answers', async (_, call) => {
    const controller = new AbortController();
    const timeout = jest.spyOn(AbortSignal, 'timeout').mockReturnValue(controller.signal);
    mocks.fetch.mockImplementationOnce(
      (_url, options) =>
        new Promise<Response>((_resolve, reject) => {
          options!.signal!.addEventListener('abort', () => reject(options!.signal!.reason as Error), { once: true });
        }),
    );

    const pending = call(sut);
    expect(timeout).toHaveBeenCalledWith(10_000);
    controller.abort(new DOMException('Support mode timed out', 'TimeoutError'));

    await expect(pending).rejects.toThrow('Support mode timed out');
  });
});
