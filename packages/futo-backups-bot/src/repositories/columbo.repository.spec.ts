import { jest } from '@jest/globals';
import { env } from 'src/env.js';
import { ColumboRepository } from './columbo.repository.js';

describe(ColumboRepository.name, () => {
  let sut: ColumboRepository;
  let mocks: { fetch: jest.SpiedFunction<typeof fetch>; originalUrl: string };

  beforeEach(() => {
    mocks = { fetch: jest.spyOn(globalThis, 'fetch'), originalUrl: env.COLUMBO_URL };
    env.COLUMBO_URL = 'http://columbo.test';
    sut = new ColumboRepository();
  });

  afterEach(() => {
    env.COLUMBO_URL = mocks.originalUrl;
    jest.restoreAllMocks();
  });

  it('fetches scoped version evidence without starting an LLM investigation', async () => {
    const result = {
      versions: [{ component: 'orchestration-api (client)', version: '1.2.1', source: 'logs' }],
      unavailableSources: ['metrics'],
    };
    mocks.fetch.mockResolvedValue(Response.json(result));

    await expect(sut.getVersions('user/1')).resolves.toEqual(result);

    expect(mocks.fetch).toHaveBeenCalledWith(
      new URL('http://columbo.test/internal/users/user%2F1/versions'),
      expect.objectContaining({
        headers: { 'X-Internal-Secret': env.INTERNAL_SECRET },
        signal: expect.any(AbortSignal),
      }),
    );
    expect(mocks.fetch).toHaveBeenCalledTimes(1);
  });

  it('reports an unavailable version endpoint', async () => {
    mocks.fetch.mockResolvedValue(new Response(null, { status: 503 }));

    await expect(sut.getVersions('user-1')).rejects.toThrow('version lookup failed: 503');
  });

  it('skips requests when the integration is unconfigured', async () => {
    env.COLUMBO_URL = '';

    await expect(sut.getVersions('user-1')).resolves.toBeNull();

    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it('sends staff prompts and conversation with the retry request', async () => {
    mocks.fetch.mockResolvedValue(new Response(null, { status: 202 }));
    const request = {
      ticketThreadId: 't1',
      staffThreadId: 's1',
      discordUserId: 'd1',
      username: 'someone',
      userId: 'u1',
      description: 'original issue',
      prompt: 'Look for a fix',
      conversation: 'restore failed',
      requestedBy: 'staff-1',
    };

    await sut.requestInvestigation(request);

    expect(mocks.fetch).toHaveBeenCalledWith(
      new URL('http://columbo.test/internal/investigations'),
      expect.objectContaining({ method: 'POST', body: JSON.stringify(request), signal: expect.any(AbortSignal) }),
    );
  });
});
