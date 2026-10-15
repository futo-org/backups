import { type WriteStream } from 'node:fs';

export class JobContext {
  constructor(
    readonly signal: AbortSignal,
    readonly logWriter: WriteStream,
  ) {}
}
