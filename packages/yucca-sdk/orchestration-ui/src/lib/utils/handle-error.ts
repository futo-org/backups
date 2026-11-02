import { toastManager } from '@immich/ui';
import { gt } from 'svelte-i18n-lingui';

let isPageUnloading = false;

if (globalThis.window !== undefined) {
  const markPageUnloading = () => {
    isPageUnloading = true;
  };
  globalThis.addEventListener('pagehide', markPageUnloading);
  globalThis.addEventListener('beforeunload', markPageUnloading);
  globalThis.addEventListener('pageshow', () => {
    isPageUnloading = false;
  });
}

function isServerError(error: unknown) {
  if (typeof error !== 'object' || error === null) {
    return false;
  }

  const { status, data } = error as { status?: unknown; data?: unknown };
  return status !== undefined || data !== undefined;
}

export function getServerErrorMessage(error: {
  data?: { message?: string };
  message?: string;
}) {
  // errors for endpoints without return types aren't parsed as json
  let data = error.data;
  if (typeof data === 'string') {
    try {
      data = JSON.parse(data);
    } catch {
      // Not a JSON string
    }
  }

  return data?.message || error.message;
}

export function standardizeError(error: unknown) {
  return error instanceof Error ? error : new Error(String(error));
}

export function getReadableErrorMessage(error: unknown): string {
  return (
    getServerErrorMessage(error as never) ||
    standardizeError(error).message ||
    gt`An unknown error occurred`
  );
}

export function handleError(error: unknown, localizedMessage: string) {
  const standardizedError = standardizeError(error);
  if (standardizedError.name === 'AbortError') {
    return;
  }

  console.error(
    `[handleError]: ${standardizedError}`,
    error,
    standardizedError.stack,
  );

  if (isPageUnloading) {
    return;
  }

  try {
    let serverMessage = isServerError(error)
      ? getServerErrorMessage(error as never)
      : undefined;
    if (serverMessage) {
      serverMessage = `${String(serverMessage).slice(0, 75)}\n(Yucca Server Error)`;
    }

    const errorMessage = serverMessage || localizedMessage;

    toastManager.danger(errorMessage);

    return errorMessage;
  } catch (error) {
    console.error(error);
    return localizedMessage;
  }
}
