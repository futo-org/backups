import { jest } from '@jest/globals';
import { createRetryingFetch } from './retryingFetch.js';

const connectTimeout = () =>
  new TypeError('fetch failed', {
    cause: Object.assign(new Error('Connect Timeout Error'), { code: 'UND_ERR_CONNECT_TIMEOUT' }),
  });

const respond = (status: number) => new Response('body', { status });

const setup = (...outcomes: Array<number | Error>) => {
  const fetch = jest.fn<typeof globalThis.fetch>();
  for (const outcome of outcomes) {
    if (outcome instanceof Error) {
      fetch.mockRejectedValueOnce(outcome);
    } else {
      fetch.mockResolvedValueOnce(respond(outcome));
    }
  }
  return { fetch, retryingFetch: createRetryingFetch({ fetch, maxAttempts: 4, baseDelayMs: 1 }) };
};

describe(createRetryingFetch.name, () => {
  it('retries a 502 until the backend answers', async () => {
    const { fetch, retryingFetch } = setup(502, 503, 200);

    await expect(retryingFetch('https://backups.test/api/repository/id')).resolves.toMatchObject({ status: 200 });
    expect(fetch).toHaveBeenCalledTimes(3);
  });

  it('retries a connect timeout until the backend answers', async () => {
    const { fetch, retryingFetch } = setup(connectTimeout(), 200);

    await expect(retryingFetch('https://backups.test/api/auth', { method: 'GET' })).resolves.toMatchObject({
      status: 200,
    });
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it('returns the last transient response once the attempts run out', async () => {
    const { fetch, retryingFetch } = setup(502, 502, 502, 504);

    await expect(retryingFetch('https://backups.test/api/auth')).resolves.toMatchObject({ status: 504 });
    expect(fetch).toHaveBeenCalledTimes(4);
  });

  it('rethrows the last network error once the attempts run out', async () => {
    const { fetch, retryingFetch } = setup(connectTimeout(), connectTimeout(), connectTimeout(), connectTimeout());

    await expect(retryingFetch('https://backups.test/api/auth')).rejects.toThrow('fetch failed');
    expect(fetch).toHaveBeenCalledTimes(4);
  });

  it('does not retry non-idempotent requests', async () => {
    const { fetch, retryingFetch } = setup(connectTimeout());

    await expect(retryingFetch('https://backups.test/api/repository', { method: 'POST' })).rejects.toThrow(
      'fetch failed',
    );
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it('does not retry client errors', async () => {
    const { fetch, retryingFetch } = setup(404);

    await expect(retryingFetch('https://backups.test/api/repository/id')).resolves.toMatchObject({ status: 404 });
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it('does not retry once the caller aborted', async () => {
    const controller = new AbortController();
    const { fetch, retryingFetch } = setup();
    fetch.mockImplementationOnce(() => {
      controller.abort();
      return Promise.reject(connectTimeout());
    });

    await expect(retryingFetch('https://backups.test/api/auth', { signal: controller.signal })).rejects.toThrow(
      'fetch failed',
    );
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it('stops backing off once a Request signal aborts', async () => {
    const controller = new AbortController();
    const fetch = jest.fn<typeof globalThis.fetch>().mockRejectedValue(connectTimeout());
    const retryingFetch = createRetryingFetch({ fetch, maxAttempts: 4, baseDelayMs: 60_000 });
    const request = new Request('https://backups.test/api/auth', { signal: controller.signal });

    const pending = retryingFetch(request);
    await new Promise((resolve) => setImmediate(resolve));
    controller.abort();

    await expect(pending).rejects.toMatchObject({ name: 'AbortError' });
    expect(fetch).toHaveBeenCalledTimes(1);
  });
});
