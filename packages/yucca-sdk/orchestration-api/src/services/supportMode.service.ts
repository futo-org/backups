import { ForbiddenException, Injectable } from '@nestjs/common';
import { dirname } from 'node:path';
import packageJson from '../../package.json' with { type: 'json' };
import { YuccaBackend } from '../backends/yucca.backend.js';
import { REPOSITORY_DEFAULT_CLOUD_UUID, SUPPORT_LOG_STREAMING_FEATURE } from '../const.js';
import { SupportModeResponseDto, SupportModeUpdateRequestDto } from '../dto/supportMode.dto.js';
import { JobName } from '../enum.js';
import { BackendRepository } from '../repositories/backend.repository.js';
import { ConfigRepository, SupportModeSettings } from '../repositories/config.repository.js';
import { LoggingRepository } from '../repositories/logging.repository.js';
import { StorageRepository } from '../repositories/storage.repository.js';
import { SupportLogShipper } from '../utils/supportLogShipper.js';
import { createPathRedactor } from '../utils/supportRedaction.js';
import { SupportSession, SupportStream } from '../utils/supportSession.js';

const SUPPORT_MODE_JOBS = new Set<JobName>([
  JobName.RepositoryBackup,
  JobName.RepositoryPrune,
  JobName.RepositoryRestore,
  JobName.RepositoryRestoreFromPoint,
  JobName.RepositorySnapshotForget,
]);

export const supportLogFilePath = (logFilePath: string) => logFilePath.replace(/\.jsonl$/, '.support.jsonl');

@Injectable()
export class SupportModeService {
  static streamOpenTimeoutMs = 10_000;

  constructor(
    private readonly config: ConfigRepository,
    private readonly backends: BackendRepository,
    private readonly storage: StorageRepository,
    private readonly logger: LoggingRepository,
  ) {
    this.logger.setContext(SupportModeService.name);
  }

  async get(): Promise<SupportModeResponseDto> {
    return { ...(await this.config.getSupportMode()), streamingAvailable: await this.isStreamingAvailable() };
  }

  async update(dto: SupportModeUpdateRequestDto): Promise<SupportModeResponseDto> {
    const streamingAvailable = await this.isStreamingAvailable();
    if (dto.streamToFuto && !streamingAvailable) {
      throw new ForbiddenException('Streaming support logs to FUTO is not enabled for this account');
    }

    await this.config.setSupportMode(dto);

    return { ...dto, streamingAvailable };
  }

  async begin(job: { id: string; name: JobName }, logFilePath: string): Promise<SupportSession | undefined> {
    if (!SUPPORT_MODE_JOBS.has(job.name)) {
      return;
    }

    const settings = await this.config.consumeSupportModeRun();
    if (!settings) {
      return;
    }

    const localPath = supportLogFilePath(logFilePath);
    await this.storage.mkdir(dirname(localPath), { recursive: true });
    const stream = settings.streamToFuto ? await this.openStream(job, settings) : undefined;

    return new SupportSession(this.storage.createWriteStream(localPath), stream);
  }

  private async openStream(
    job: { id: string; name: JobName },
    settings: SupportModeSettings,
  ): Promise<SupportStream | undefined> {
    try {
      const backend = await this.getCloudBackend();
      if (!backend) {
        this.logger.warn(`Support logs for job ${job.id} stay local: no FUTO account is connected`);
        return;
      }

      const { id, token, url, expiresAt } = await backend.createSupportLogSession(
        {
          jobId: job.id,
          jobName: job.name,
          includesPaths: settings.includePaths,
          clientVersion: packageJson.version,
        },
        AbortSignal.timeout(SupportModeService.streamOpenTimeoutMs),
      );

      const shipper = new SupportLogShipper({
        url,
        credentials: { token, expiresAt: new Date(expiresAt) },
        refresh: async () => {
          const refreshed = await backend.refreshSupportLogSessionToken(id);
          return { token: refreshed.token, expiresAt: new Date(refreshed.expiresAt) };
        },
      });

      return { sessionId: id, shipper, redact: settings.includePaths ? undefined : createPathRedactor() };
    } catch (error) {
      this.logger.warn(`Support logs for job ${job.id} stay local: could not open a streaming session`, error);
    }
  }

  private async isStreamingAvailable() {
    try {
      const backend = await this.getCloudBackend();
      if (!backend) {
        return false;
      }

      const features = await backend.getFeatures();
      return features[SUPPORT_LOG_STREAMING_FEATURE] === true;
    } catch (error) {
      this.logger.warn('Could not determine whether support log streaming is available', error);
      return false;
    }
  }

  private async getCloudBackend() {
    const result = await this.backends.getBackend(REPOSITORY_DEFAULT_CLOUD_UUID);
    return result?.backend instanceof YuccaBackend ? result.backend : undefined;
  }
}
