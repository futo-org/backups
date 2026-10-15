import { Injectable, OnApplicationBootstrap } from '@nestjs/common';
import { BootstrapRepository } from '../repositories/bootstrap.repository.js';
import { ConfigRepository } from '../repositories/config.repository.js';
import { DatabaseRepository } from '../repositories/database.repository.js';
import { LoggingRepository } from '../repositories/logging.repository.js';
import { ModuleConfigRepository } from '../repositories/moduleConfig.repository.js';
import { discardStateCacheDirectory } from '../utils/cache.js';
import { ConfigService } from './config.service.js';
import { JobService } from './job.service.js';
import { RunHistoryService } from './runHistory.service.js';
import { ScheduleService } from './schedule.service.js';

@Injectable()
export class BootstrapService implements OnApplicationBootstrap {
  constructor(
    private readonly logger: LoggingRepository,
    private readonly database: DatabaseRepository,
    private readonly jobService: JobService,
    private readonly config: ConfigRepository,
    private readonly configService: ConfigService,
    private readonly schedule: ScheduleService,
    private readonly bootstrap: BootstrapRepository,
    private readonly runHistory: RunHistoryService,
    private readonly moduleConfig: ModuleConfigRepository,
  ) {
    this.logger.setContext(BootstrapService.name);
  }

  async onApplicationBootstrap() {
    try {
      if (this.moduleConfig.hasLock()) {
        await discardStateCacheDirectory(this.moduleConfig.get());
      }

      await this.database.runMigrations();
      await this.config.bootstrap();
      await this.configService.bootstrap();
      await this.schedule.bootstrap();
      await this.jobService.bootstrap();
      await this.runHistory.reconcileInterruptedRuns();

      const { backends, repositories, activeSchedules } = await this.config.getStateSummary();
      this.logger.log('Successfully finished FUTO Backups bootstrap.');
      this.logger.log(
        `Found ${backends} ${backends === 1 ? 'backend' : 'backends'}, ${repositories} ${repositories === 1 ? 'repository' : 'repositories'}, and ${activeSchedules} active ${activeSchedules === 1 ? 'schedule' : 'schedules'}.`,
      );

      this.bootstrap.markReady();
    } catch (error) {
      this.logger.error('Failed to initialise FUTO Backups with cause:', error);
      this.bootstrap.markFailed(error);
    }
  }
}
