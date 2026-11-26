const OPENABLE_PROTOCOLS = new Set(['http:', 'https:']);

export function toOpenableUrl(url: string) {
  const parsed = new URL(url);
  if (!OPENABLE_PROTOCOLS.has(parsed.protocol)) {
    throw new Error(`Refusing to open a ${parsed.protocol} URL`);
  }

  return parsed.href;
}

export function openUrl(url: string, target: string) {
  window.open(toOpenableUrl(url), target);
}
