const CORRECTION_HALF_LIFE_MS = 60_000;
const DEADBAND_MS = 30_000;
const DEADBAND_SHARE = 0.03;

export type ShownEstimate = { remaining: number; at: number };

export const easeRemaining = (shown: ShownEstimate | undefined, remaining: number, now: number): ShownEstimate => {
  if (!shown) {
    return { remaining: Math.max(remaining, 0), at: now };
  }

  const elapsed = now - shown.at;
  const counted = shown.remaining - elapsed;
  const eased = counted + (remaining - counted) * (1 - 0.5 ** (elapsed / CORRECTION_HALF_LIFE_MS));
  return { remaining: Math.max(eased, 0), at: now };
};

export const holdPublishedEnd = (published: string | undefined, shown: ShownEstimate) => {
  const end = shown.at + shown.remaining;
  const publishedAt = published ? Date.parse(published) : 0;
  const deadband = Math.max(DEADBAND_MS, shown.remaining * DEADBAND_SHARE);
  if (publishedAt > shown.at && Math.abs(end - publishedAt) <= deadband) {
    return published;
  }

  const endAt = new Date(end);
  return Number.isNaN(endAt.getTime()) ? undefined : endAt.toISOString();
};
