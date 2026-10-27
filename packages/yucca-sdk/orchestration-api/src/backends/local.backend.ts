/* eslint-disable @typescript-eslint/require-await */

import {
  RepositoryCreateRequestDto,
  RepositoryCreateResponseDto,
  RepositoryGetResponseDto,
  RepositoryListResponseDto,
  RepositoryUpdateRequestDto,
  RepositoryUpdateResponseDto,
  RepositoryWithMetricsDto,
  TicketCreateRequestDto,
  TicketCreateResponseDto,
} from '@futo-org/backups-api-client';
import { randomUUID } from 'node:crypto';
import { mkdir, readdir, stat } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { BackendType } from '../enum.js';
import { BackendConfiguration } from '../schema/tables/backend.table.js';
import { Backend } from './backend.js';
import { LocalMetadata } from './local.metadata.js';

const UNKNOWN_REPOSITORY_NAME = 'Unknown';

export class LocalBackend extends Backend {
  constructor(protected readonly configuration: BackendConfiguration & { type: BackendType.Local }) {
    super(configuration);
  }

  isBackupCapable(): boolean {
    return true;
  }

  isMetricsCapable(): boolean {
    return false;
  }

  async checkOnline(): Promise<void> {}

  private repositoryPath(id: string) {
    const root = resolve(this.configuration.path);
    const path = resolve(root, id);
    if (dirname(path) !== root) {
      throw new Error(`Invalid repository id ${id}`);
    }
    return path;
  }

  private metadata(id: string) {
    return new LocalMetadata(this.repositoryPath(id));
  }

  private async readName(id: string): Promise<string> {
    const { name } = await this.metadata(id).read();
    return name ?? UNKNOWN_REPOSITORY_NAME;
  }

  private toRepository(id: string, name: string, worm = false): RepositoryWithMetricsDto {
    return {
      id,
      name,
      worm,
      siteCode: null,
      storageClusterCode: null,
      connectionId: '',
      connectionType: 'local',
      metrics: {
        sizeBytes: 0,
      },
    };
  }

  async createRepository(dto: RepositoryCreateRequestDto): Promise<RepositoryCreateResponseDto> {
    const id = randomUUID();

    await mkdir(this.repositoryPath(id), {
      recursive: true,
    });
    await this.metadata(id).update({ name: dto.name });

    return {
      repository: this.toRepository(id, dto.name, dto.worm),
    };
  }

  async updateRepository(id: string, dto: RepositoryUpdateRequestDto): Promise<RepositoryUpdateResponseDto> {
    if (dto.name !== undefined) {
      await this.metadata(id).update({ name: dto.name });
    }

    return {
      repository: this.toRepository(id, dto.name ?? (await this.readName(id)), dto.worm),
    };
  }

  async getRepository(id: string): Promise<RepositoryGetResponseDto> {
    const stats = await stat(this.repositoryPath(id));
    if (!stats.isDirectory()) {
      throw new Error(`Repository ${id} is not a directory`);
    }

    return {
      repository: this.toRepository(id, await this.readName(id)),
    };
  }

  async getRepositories(): Promise<RepositoryListResponseDto> {
    let files: string[];
    try {
      files = await readdir(resolve(this.configuration.path));
    } catch {
      files = [];
    }

    const stats = await Promise.all(files.map((file) => stat(this.repositoryPath(file))));
    const ids = files.filter((_, index) => stats[index].isDirectory());

    return {
      repositories: await Promise.all(ids.map(async (id) => this.toRepository(id, await this.readName(id)))),
    };
  }

  async deleteRepository(_id: string): Promise<void> {
    throw new Error('Method not implemented.');
  }

  async createTicket(_dto: TicketCreateRequestDto): Promise<TicketCreateResponseDto> {
    throw new Error('Invalid backend for method');
  }

  async getResticEndpoint(id: string): Promise<string> {
    return this.repositoryPath(id);
  }

  submitMetricBackupStart(): void {
    throw new Error('not capable');
  }

  submitMetricBackupEnd(): void {
    throw new Error('not capable');
  }

  submitMetricRepositorySize(): void {
    throw new Error('not capable');
  }

  submitStructuredLog(): void {
    throw new Error('not capable');
  }
}
