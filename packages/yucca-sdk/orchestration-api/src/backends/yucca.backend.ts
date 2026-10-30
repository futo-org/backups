import {
  BackupStatus,
  createRepository,
  createResticUrl,
  createSupportLogSession,
  createTicket,
  getAuth,
  getRepositories,
  getRepository,
  refreshSupportLogSessionToken,
  RepositoryCreateRequestDto,
  RepositoryUpdateRequestDto,
  submitMetricBackupEnd,
  submitMetricBackupStart,
  submitMetricRepositorySize,
  submitStructuredLog,
  SupportLogSessionCreateRequestDto,
  TicketCreateRequestDto,
  TicketCreateResponseDto,
  updateRepository,
} from '@futo-org/backups-api-client';
import { BackendType, CookieName } from '../enum.js';
import { ResticProxyPool } from '../proxy/resticProxyPool.js';
import { LoggingRepository } from '../repositories/logging.repository.js';
import { BackendConfiguration } from '../schema/tables/backend.table.js';
import { retryingFetch } from '../utils/retryingFetch.js';
import { yuccaWellKnown } from '../wellKnown.js';
import { Backend } from './backend.js';

export class YuccaBackend extends Backend {
  private readonly logger = LoggingRepository.create(YuccaBackend.name);
  private readonly proxyPool = new ResticProxyPool();

  constructor(protected readonly configuration: BackendConfiguration & { type: BackendType.Yucca; url?: string }) {
    super(configuration);
  }

  private async getRequestOptions() {
    return {
      baseUrl: this.configuration.url ?? (await yuccaWellKnown.getBaseUrl()),
      fetch: retryingFetch,
      headers: {
        cookie: `${CookieName.YuccaAccessToken}=${this.configuration.accessToken}`,
      },
    };
  }

  isBackupCapable(): boolean {
    return true;
  }

  isMetricsCapable(): boolean {
    return true;
  }

  async checkOnline() {
    await getAuth(await this.getRequestOptions());
  }

  async getFeatures() {
    const { features } = await getAuth(await this.getRequestOptions());
    return features;
  }

  async createSupportLogSession(dto: SupportLogSessionCreateRequestDto, signal?: AbortSignal) {
    return await createSupportLogSession(dto, { ...(await this.getRequestOptions()), signal });
  }

  async refreshSupportLogSessionToken(id: string) {
    return await refreshSupportLogSessionToken(id, await this.getRequestOptions());
  }

  async createRepository(dto: RepositoryCreateRequestDto) {
    return await createRepository(dto, await this.getRequestOptions());
  }

  async updateRepository(id: string, dto: RepositoryUpdateRequestDto) {
    return await updateRepository(id, dto, await this.getRequestOptions());
  }

  async getRepository(id: string) {
    return await getRepository(id, await this.getRequestOptions());
  }

  async getRepositories() {
    return await getRepositories(await this.getRequestOptions());
  }

  async deleteRepository() {}

  async createTicket(dto: TicketCreateRequestDto): Promise<TicketCreateResponseDto> {
    return await createTicket(dto, await this.getRequestOptions());
  }

  async getResticEndpoint(id: string) {
    const requestOptions = await this.getRequestOptions();

    const proxyAvailable = await this.proxyPool.isAvailable();
    if (proxyAvailable) {
      try {
        const proxy = await this.proxyPool.getProxy(`${requestOptions.baseUrl}/api`);
        return proxy.createUrl(id, this.configuration.accessToken);
      } catch (error) {
        this.logger.warn('Falling back to a direct restic URL', error);
      }
    }

    const { url } = await createResticUrl(id, requestOptions);
    return url;
  }

  submitMetricBackupStart(id: string): void {
    void this.getRequestOptions()
      .then((requestOptions) => submitMetricBackupStart(id, requestOptions))
      .catch((error) => this.logger.error('Failed to submit backup start metric', error));
  }

  submitMetricBackupEnd(id: string, status: BackupStatus, durationMs: number): void {
    void this.getRequestOptions()
      .then((requestOptions) => submitMetricBackupEnd(id, { durationMs, status }, requestOptions))
      .catch((error) => this.logger.error('Failed to submit backup end metric', error));
  }

  submitMetricRepositorySize(id: string, sizeBytes: number): void {
    void this.getRequestOptions()
      .then((requestOptions) => submitMetricRepositorySize(id, { sizeBytes }, requestOptions))
      .catch((error) => this.logger.error('Failed to submit repository size metric', error));
  }

  submitStructuredLog(summary: string, data: object) {
    void this.getRequestOptions()
      .then((requestOptions) => submitStructuredLog({ summary, data }, requestOptions))
      .catch((error) => this.logger.error('Failed to submit log', error));
  }
}
