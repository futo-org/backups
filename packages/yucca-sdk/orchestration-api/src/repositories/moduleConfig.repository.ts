import { BeforeApplicationShutdown, Inject, Injectable } from '@nestjs/common';
import { EventEmitter2 } from '@nestjs/event-emitter';
import { InternalEvent } from '../enum.js';
import { type ModuleConfig, ModuleConfigProvider } from '../moduleConfig.js';

@Injectable()
export class ModuleConfigRepository implements BeforeApplicationShutdown {
  private releaseLock?: () => Promise<void>;
  private config: ModuleConfig;

  constructor(
    @Inject(ModuleConfigProvider) initial: ModuleConfig,
    private readonly eventEmitter: EventEmitter2,
  ) {
    this.config = { ...initial };
  }

  get(): ModuleConfig {
    return this.config;
  }

  update(partial: Partial<ModuleConfig>) {
    this.config = { ...this.config, ...partial };
    this.eventEmitter.emit(InternalEvent.ModuleConfigUpdated, this.config);
  }

  acquireLock(release: () => Promise<void>) {
    this.releaseLock = release;
  }

  hasLock() {
    return this.releaseLock !== undefined || !this.config.requireLock;
  }

  async beforeApplicationShutdown() {
    await this.releaseLock?.();
  }
}
