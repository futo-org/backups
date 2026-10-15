import { Job } from '../decorators.js';
import { JobName } from '../enum.js';
import { RepositoryService } from '../services/repository.service.js';
import type { JobHandler } from '../utils/types.js';

type RepositorySyncMetricsData = {
  repositoryId: string;
};

@Job({ name: JobName.RepositorySyncMetrics })
export class RepositorySyncMetricsJob implements JobHandler<RepositorySyncMetricsData> {
  constructor(private readonly repositoryService: RepositoryService) {}

  async run({ repositoryId }: RepositorySyncMetricsData): Promise<void> {
    const resticParameters = await this.repositoryService.getResticParameters(repositoryId);
    await this.repositoryService.updateLocalMetrics(repositoryId, { resticParameters });
  }
}
