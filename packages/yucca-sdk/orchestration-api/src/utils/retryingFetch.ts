import { setTimeout as sleep } from 'node:timers/promises';

export type RetryOptions = {
  maxAttempts: number;
  baseDelayMs: number;
  fetch: typeof fetch;
};

const DEFAULT_OPTIONS: RetryOptions = {
  maxAttempts: 5,
  baseDelayMs: 1000,
  fetch: (input, init) => fetch(input, init),
};

const IDEMPOTENT_METHODS = new Set(['GET', 'HEAD']);
const TRANSIENT_STATUSES = new Set([500, 502, 503, 504]);

const getMethod = (input: string | URL | Request, init?: RequestInit) =>
  (init?.method ?? (input instanceof Request ? input.method : 'GET')).toUpperCase();

const getSignal = (input: string | URL | Request, init?: RequestInit) =>
  (init?.signal === undefined ? (input instanceof Request ? input.signal : undefined) : init.signal) ?? undefined;

const jitter = (delayMs: number) => delayMs / 2 + Math.random() * (delayMs / 2);

export const createRetryingFetch = (overrides: Partial<RetryOptions> = {}): typeof fetch => {
  const options = { ...DEFAULT_OPTIONS, ...overrides };

  return async (input, init) => {
    if (!IDEMPOTENT_METHODS.has(getMethod(input, init))) {
      return await options.fetch(input, init);
    }

    const signal = getSignal(input, init);
    for (let attempt = 1; ; attempt++) {
      const isLastAttempt = attempt >= options.maxAttempts;
      try {
        const response = await options.fetch(input, init);
        if (isLastAttempt || !TRANSIENT_STATUSES.has(response.status)) {
          return response;
        }
        await response.body?.cancel();
      } catch (error) {
        if (isLastAttempt || signal?.aborted || !(error instanceof TypeError)) {
          throw error;
        }
      }

      await sleep(jitter(options.baseDelayMs * 2 ** (attempt - 1)), undefined, { signal });
    }
  };
};

export const retryingFetch = createRetryingFetch();
