import { BadRequestException, Injectable, Post } from '@nestjs/common';
import { DatabaseRepository } from '../repositories/database.repository.js';
import { ModuleConfigRepository } from '../repositories/moduleConfig.repository.js';
import { BootstrapService } from './bootstrap.service.js';

@Injectable()
export class DevelopmentService {
  constructor(
    private readonly database: DatabaseRepository,
    private readonly moduleConfig: ModuleConfigRepository,
    private readonly bootstrap: BootstrapService,
  ) {}

  @Post('reset')
  async resetOrchestrator(): Promise<void> {
    if (!this.moduleConfig.get().developmentMode) {
      throw new BadRequestException('Not in development mode');
    }

    await this.database.resetMigrations();

    await this.bootstrap.onApplicationBootstrap();
  }
}
