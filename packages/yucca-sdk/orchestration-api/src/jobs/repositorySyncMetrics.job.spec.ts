import { jest } from '@jest/globals';
import { RepositorySyncMetricsJob } from './repositorySyncMetrics.job.js';

describe(RepositorySyncMetricsJob.name, () => {
  it('refreshes local metrics from the repository restic stats', async () => {
    const resticParameters = {
      endpoint: 'rest:https://example.com/repository',
      key: new Uint8Array([1, 2, 3]),
      placement: { siteCode: null, storageClusterCode: null },
    };
    const repositoryService = {
      getResticParameters: jest.fn<() => Promise<typeof resticParameters>>().mockResolvedValue(resticParameters),
      updateLocalMetrics: jest.fn(),
    };
    const job = new RepositorySyncMetricsJob(repositoryService as never);

    await job.run({ repositoryId: 'repository-1' });

    expect(repositoryService.updateLocalMetrics).toHaveBeenCalledWith('repository-1', { resticParameters });
  });
});
