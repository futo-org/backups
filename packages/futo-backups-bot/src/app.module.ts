import { LoggerRepository, LoggingInterceptor, OtelModule, WideContextRepository } from '@common/server/otel';
import { Module } from '@nestjs/common';
import { APP_INTERCEPTOR } from '@nestjs/core';
import { ScheduleModule } from '@nestjs/schedule';
import { InternalController } from './controllers/internal.controller.js';
import { WebhookController } from './controllers/webhook.controller.js';
import { ColumboRepository } from './repositories/columbo.repository.js';
import { DiscordRepository } from './repositories/discord.repository.js';
import { FreshdeskRepository } from './repositories/freshdesk.repository.js';
import { TranscriptStorageRepository } from './repositories/transcriptStorage.repository.js';
import { YuccaApiRepository } from './repositories/yuccaApi.repository.js';
import { FreshdeskSyncService } from './services/freshdeskSync.service.js';
import { InviteService } from './services/invite.service.js';
import { SupportService } from './services/support.service.js';
import { SweepService } from './services/sweep.service.js';

export const imports = [ScheduleModule.forRoot()];

export const providers = [
  WideContextRepository,
  LoggerRepository,
  ColumboRepository,
  DiscordRepository,
  YuccaApiRepository,
  FreshdeskRepository,
  TranscriptStorageRepository,
  FreshdeskSyncService,
  InviteService,
  SupportService,
  SweepService,
  { provide: APP_INTERCEPTOR, useClass: LoggingInterceptor },
];

@Module({
  imports: [OtelModule, ...imports],
  controllers: [InternalController, WebhookController],
  providers,
})
export class AppModule {}
