import { BackendRepository } from '../src/repositories/backend.repository.js';
import { BackendService } from '../src/services/backend.service.js';
import { createTestingModule, TestContext } from './testUtils.js';

let ctx: TestContext;

beforeAll(async () => {
  ctx = await createTestingModule();
}, 15_000);

afterAll(async () => {
  await ctx.app.close();
});

describe('Backend', () => {
  it('reports online for a healthy local backend', async () => {
    const backendService = ctx.module.get(BackendService);

    const { backends } = await backendService.getBackends();
    const backend = backends.find((backend) => backend.id === ctx.backendId);

    expect(backend).toEqual(
      expect.objectContaining({
        id: ctx.backendId,
        type: 'local',
        isOnline: true,
      }),
    );
  });

  it('lists multiple backends', async () => {
    const backendService = ctx.module.get(BackendService);
    const backendRepository = ctx.module.get(BackendRepository);

    await backendRepository.updateBackend('second-backend', {
      type: 'local' as any,
      path: ctx.backendPath,
    });

    const { backends } = await backendService.getBackends();

    expect(backends.length).toBeGreaterThanOrEqual(2);
    expect(backends.find((backend) => backend.id === ctx.backendId)).toBeDefined();
    expect(backends.find((backend) => backend.id === 'second-backend')).toBeDefined();
  });
});
