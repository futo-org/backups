import { type Writable } from 'node:stream';

export class JobContext {
  constructor(
    readonly signal: AbortSignal,
    readonly logWriter: Writable,
  ) {}
}
