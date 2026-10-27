import { jest } from '@jest/globals';
import type { WriteStream } from 'node:fs';
import { JobContext, type JobLogEvent } from './jobContext.js';

const megabyte = 1000 * 1000;

const createContext = () =>
  new JobContext(new AbortController().signal, { write: () => true } as unknown as WriteStream);

const status = (seconds: number, bytesDone: number, totalBytes: number, scanFinished = true) => {
  jest.setSystemTime(seconds * 1000);
  return {
    message_type: 'status',
    percent_done: bytesDone / totalBytes,
    bytes_done: bytesDone,
    total_bytes: totalBytes,
    ...(scanFinished ? { seconds_remaining: 1 } : {}),
  } as JobLogEvent;
};

const uploadSteadily = (context: JobContext, totalBytes: number, until: number, bytesPerSecond = 10 * megabyte) => {
  for (let second = 0; second <= until; second++) {
    context.log(status(second, second * bytesPerSecond, totalBytes));
  }
};

const secondsRemaining = (context: JobContext) =>
  context.progress?.estimatedEndAt && (Date.parse(context.progress.estimatedEndAt) - Date.now()) / 1000;

describe(JobContext.name, () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('gives no estimate while restic is still scanning', () => {
    const context = createContext();

    for (let second = 0; second <= 60; second++) {
      context.log(status(second, second * 10 * megabyte, 2000 * megabyte, false));
    }

    expect(secondsRemaining(context)).toBeUndefined();
  });

  it('marks progress as scanning until restic has counted every file', () => {
    const context = createContext();

    context.log(status(0, 50 * megabyte, 400 * megabyte, false));
    expect(context.progress?.scanning).toBe(true);

    context.log(status(1, 60 * megabyte, 36_000 * megabyte));
    expect(context.progress?.scanning).toBe(false);
  });

  it('treats a restore as scanned from its first status', () => {
    const context = createContext();

    context.log({
      message_type: 'status',
      percent_done: 0.1,
      bytes_restored: 10 * megabyte,
      total_bytes: 100 * megabyte,
    } as JobLogEvent);

    expect(context.progress?.scanning).toBe(false);
  });

  it('ignores bytes read while scanning when estimating the upload rate', () => {
    const context = createContext();
    context.log(status(0, 844 * megabyte, 31_000 * megabyte, false));

    for (let second = 1; second <= 300; second++) {
      context.log(status(second, 844 * megabyte, 36_000 * megabyte));
    }

    expect(secondsRemaining(context)).toBeUndefined();
  });

  it('keeps the same progress when restic repeats an unchanged status', () => {
    const context = createContext();
    context.log(status(0, 844 * megabyte, 36_000 * megabyte, false));
    const progress = context.progress;

    context.log(status(1, 844 * megabyte, 36_000 * megabyte, false));

    expect(context.progress).toBe(progress);
  });

  it('estimates the time left from the average upload rate', () => {
    const context = createContext();

    uploadSteadily(context, 3000 * megabyte, 240);

    expect(secondsRemaining(context)).toBe(60);
  });

  it('reports nothing left once files grew past the scanned total', () => {
    const context = createContext();

    uploadSteadily(context, 1000 * megabyte, 240);

    expect(context.progress?.percentDone).toBe(1);
    expect(secondsRemaining(context)).toBe(0);
  });

  it('keeps the published end time while the estimate wobbles slightly', () => {
    const context = createContext();
    uploadSteadily(context, 3000 * megabyte, 240);
    const publishedEnd = context.progress?.estimatedEndAt;

    context.log(status(241, 2405 * megabyte, 3000 * megabyte));
    context.log(status(242, 2420 * megabyte, 3000 * megabyte));

    expect(context.progress?.estimatedEndAt).toBe(publishedEnd);
  });

  it('eases towards a slower estimate while uploads stall instead of jumping to it', () => {
    const context = createContext();
    uploadSteadily(context, 3000 * megabyte, 240);

    for (let second = 241; second <= 300; second++) {
      context.log(status(second, 2400 * megabyte, 3000 * megabyte));
    }

    expect(secondsRemaining(context)).toBeGreaterThan(0);
    expect(secondsRemaining(context)).toBeLessThan(60);
  });

  it('starts measuring the rate once uploads move after the scan', () => {
    const context = createContext();

    for (let second = 0; second <= 80; second++) {
      context.log(status(second, 836 * megabyte, 2000 * megabyte));
    }

    for (let second = 81; second <= 300; second++) {
      context.log(status(second, (836 + (second - 80) * 10) * megabyte, 4000 * megabyte));
    }

    expect(secondsRemaining(context)).toBeCloseTo(96, 0);
  });

  it('drops the estimate instead of failing when a stall pushes it past any representable time', () => {
    const context = createContext();
    uploadSteadily(context, 3000 * megabyte, 240);

    for (let second = 241; second <= 241 + 6 * 60 * 60; second++) {
      context.log(status(second, 2400 * megabyte, 3000 * megabyte));
    }

    expect(context.progress?.estimatedEndAt).toBeUndefined();
  });

  it('starts a fresh estimate when the byte counter restarts', () => {
    const context = createContext();
    uploadSteadily(context, 3000 * megabyte, 240);

    context.log(status(241, 0, 100 * megabyte));

    expect(secondsRemaining(context)).toBeUndefined();
  });

  it('finishes progress and clears files and the estimate when the backup summary arrives', () => {
    const context = createContext();
    uploadSteadily(context, 3000 * megabyte, 240);

    context.log({
      message_type: 'summary',
      files_new: 1,
      files_changed: 0,
      total_files_processed: 1,
      total_bytes_processed: 3000 * megabyte,
      snapshot_id: 'abc',
    } as JobLogEvent);

    expect(context.progress).toMatchObject({ percentDone: 1, currentFiles: [], totalBytes: 3000 * megabyte });
    expect(context.progress?.estimatedEndAt).toBeUndefined();
  });
});
