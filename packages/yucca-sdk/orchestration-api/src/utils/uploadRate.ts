const HALF_LIFE_MS = 10 * 60_000;
const WARM_UP_MS = 10_000;

export type UploadRate = {
  bytes: number;
  duration: number;
  lastBytes: number;
  lastAt: number;
  moving: boolean;
};

export const startUploadRate = (bytes: number, at: number): UploadRate => ({
  bytes: 0,
  duration: 0,
  lastBytes: bytes,
  lastAt: at,
  moving: false,
});

export const sampleUploadRate = (rate: UploadRate, bytes: number, at: number): UploadRate => {
  if (!rate.moving) {
    return { ...rate, lastBytes: bytes, lastAt: at, moving: bytes > rate.lastBytes };
  }

  const elapsed = at - rate.lastAt;
  const decay = 0.5 ** (elapsed / HALF_LIFE_MS);
  return {
    bytes: rate.bytes * decay + bytes - rate.lastBytes,
    duration: rate.duration * decay + elapsed,
    lastBytes: bytes,
    lastAt: at,
    moving: true,
  };
};

export const getBytesPerMs = (rate: UploadRate) =>
  rate.duration >= WARM_UP_MS && rate.bytes > 0 ? rate.bytes / rate.duration : undefined;
