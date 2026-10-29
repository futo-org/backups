const PROBE_URL = 'https://docs.futo.cloud/';
const PROBE_TIMEOUT = 5000;

const CONNECTIVITY_ERROR =
  /fetch failed|ConnectTimeoutError|ECONNREFUSED|ECONNRESET|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|ENETUNREACH|EHOSTUNREACH|request timeout|backend unreachable|backups unreachable|backups unavailable|connection reset|connection refused|broken pipe|i\/o timeout|no such host|TLS handshake timeout|unexpected HTTP response \((502|503|504)\)|\b50[234] (Bad Gateway|Service Unavailable|Gateway Timeout)\b/i;
const LOCAL_FILE_ERROR = /permission denied|no such file or directory|operation not permitted|is a directory/i;

export type InternetProbe = () => Promise<boolean>;

export const probeInternet: InternetProbe = async () => {
  try {
    const response = await fetch(PROBE_URL, { signal: AbortSignal.timeout(PROBE_TIMEOUT) });
    await response.body?.cancel();
    return true;
  } catch {
    return false;
  }
};

export const isConnectivityError = (errors: string[]) =>
  errors.some((error) => CONNECTIVITY_ERROR.test(error) && !LOCAL_FILE_ERROR.test(error));

export const explainConnectivityFailure = async (errors: string[], probe: InternetProbe = probeInternet) => {
  if (!isConnectivityError(errors)) {
    return;
  }

  return (await probe())
    ? 'Could not reach FUTO Backups; your internet connection works (docs.futo.cloud reachable), so this is likely on our side'
    : 'Could not reach FUTO Backups; your internet connection also appears to be down (docs.futo.cloud unreachable)';
};
