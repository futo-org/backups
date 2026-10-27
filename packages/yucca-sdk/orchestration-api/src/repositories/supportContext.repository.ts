import { Injectable } from '@nestjs/common';
import { AsyncLocalStorage } from 'node:async_hooks';
import type { SupportSession } from '../utils/supportSession.js';

@Injectable()
export class SupportContextRepository {
  private readonly storage = new AsyncLocalStorage<SupportSession>();

  run<T>(session: SupportSession | undefined, operation: () => Promise<T>): Promise<T> {
    return session ? this.storage.run(session, operation) : operation();
  }

  current(): SupportSession | undefined {
    return this.storage.getStore();
  }
}
