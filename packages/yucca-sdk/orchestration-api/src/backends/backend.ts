import {
  BackupStatus,
  RepositoryCreateRequestDto,
  RepositoryCreateResponseDto,
  RepositoryGetResponseDto,
  RepositoryListResponseDto,
  RepositoryUpdateRequestDto,
  RepositoryUpdateResponseDto,
  TicketCreateRequestDto,
  TicketCreateResponseDto,
} from '@futo-org/backups-api-client';
import { BackendConfiguration } from '../schema/tables/backend.table.js';

export abstract class Backend {
  constructor(protected readonly configuration: BackendConfiguration) {}

  abstract isBackupCapable(): boolean;
  abstract isMetricsCapable(): boolean;

  abstract checkOnline(): Promise<void>;
  abstract createRepository(dto: RepositoryCreateRequestDto): Promise<RepositoryCreateResponseDto>;
  abstract updateRepository(id: string, dto: RepositoryUpdateRequestDto): Promise<RepositoryUpdateResponseDto>;
  abstract getRepository(id: string): Promise<RepositoryGetResponseDto>;
  abstract getRepositories(): Promise<RepositoryListResponseDto>;
  abstract deleteRepository(id: string): Promise<void>;
  abstract createTicket(dto: TicketCreateRequestDto): Promise<TicketCreateResponseDto>;

  abstract getResticEndpoint(id: string): Promise<string>;

  abstract submitMetricBackupStart(id: string): void;
  abstract submitMetricBackupEnd(id: string, status: BackupStatus, durationMs: number): void;
  abstract submitMetricRepositorySize(id: string, size: number): void;
  abstract submitStructuredLog(summary: string, data: object): void;
}
