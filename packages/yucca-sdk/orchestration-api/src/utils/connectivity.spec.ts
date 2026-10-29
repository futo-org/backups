import { jest } from '@jest/globals';
import { explainConnectivityFailure, isConnectivityError, probeInternet } from './connectivity.js';

describe(isConnectivityError.name, () => {
  it.each([
    'TypeError: fetch failed',
    'ConnectTimeoutError: Connect Timeout Error (attempted address: backups.futo.cloud:443, timeout: 10000ms)',
    'Fatal: unable to save snapshot: unexpected HTTP response (502): 502 Bad Gateway',
    'Save(<data/0a1b2c>) returned error, retrying after 1.2s: request timeout',
    'Load(<index/3d4e5f>) failed: Get "http://127.0.0.1:41234/index/3d4e5f": dial tcp 127.0.0.1:41234: connect: connection refused',
    'restic exited with code 1: Fatal: unable to open config file: Stat: Head "http://127.0.0.1:41234/config": EOF backend unreachable',
  ])('recognises %s', (error) => {
    expect(isConnectivityError([error])).toBe(true);
  });

  it.each([
    'restic exited with code 1: Fatal: wrong password or no key found',
    '/photos/a.jpg: open /photos/a.jpg: permission denied',
    'Fatal: unable to save snapshot: unexpected HTTP response (403): 403 Forbidden',
  ])('ignores %s', (error) => {
    expect(isConnectivityError([error])).toBe(false);
  });
});

describe(explainConnectivityFailure.name, () => {
  it('blames the backend when the internet is reachable', async () => {
    const probe = jest.fn(() => Promise.resolve(true));

    await expect(explainConnectivityFailure(['TypeError: fetch failed'], probe)).resolves.toBe(
      'Could not reach FUTO Backups; your internet connection works (icanhazip.com reachable), so this is likely on our side',
    );
    expect(probe).toHaveBeenCalledTimes(1);
  });

  it('blames the local network when the internet is unreachable too', async () => {
    const probe = jest.fn(() => Promise.resolve(false));

    await expect(explainConnectivityFailure(['unexpected HTTP response (503)'], probe)).resolves.toBe(
      'Could not reach FUTO Backups; your internet connection also appears to be down (icanhazip.com unreachable)',
    );
  });

  it('does not probe for unrelated failures', async () => {
    const probe = jest.fn(() => Promise.resolve(true));

    await expect(explainConnectivityFailure(['Fatal: wrong password or no key found'], probe)).resolves.toBeUndefined();
    expect(probe).not.toHaveBeenCalled();
  });
});

describe(probeInternet.name, () => {
  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('reports a successful probe as reachable', async () => {
    const fetch = jest.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('203.0.113.7\n'));

    await expect(probeInternet()).resolves.toBe(true);
    expect(fetch).toHaveBeenCalledWith(
      'https://icanhazip.com/',
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    );
  });

  it('reports a failed request as unreachable', async () => {
    jest.spyOn(globalThis, 'fetch').mockRejectedValue(new TypeError('fetch failed'));

    await expect(probeInternet()).resolves.toBe(false);
  });

  it('reports an error status as unreachable', async () => {
    jest.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('', { status: 503 }));

    await expect(probeInternet()).resolves.toBe(false);
  });
});
