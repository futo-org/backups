import { submitStructuredLog } from '@futo-org/backups-api-client';
import { jest } from '@jest/globals';
import { setTimeout as delay } from 'node:timers/promises';
import packageJson from '../package.json' with { type: 'json' };
import { REPOSITORY_DEFAULT_CLOUD_UUID } from '../src/const.js';
import { BackendType, ConfigurationKey } from '../src/enum.js';
import { BackendRepository } from '../src/repositories/backend.repository.js';
import { ConfigRepository } from '../src/repositories/config.repository.js';
import { TelemetryService } from '../src/services/telemetry.service.js';
import { yuccaWellKnown } from '../src/wellKnown.js';
import { createTestingModule, TestContext, waitFor } from './testUtils.js';

const apiSubmitStructuredLog = submitStructuredLog as jest.Mock;

let ctx: TestContext;

beforeAll(async () => {
  ctx = await createTestingModule();
}, 15_000);

afterAll(async () => {
  await ctx.app.close();
});

beforeEach(async () => {
  jest.clearAllMocks();
  // Without this the backend resolves its base URL by fetching the real
  // production .well-known over the network.
  jest.spyOn(yuccaWellKnown, 'getBaseUrl').mockResolvedValue('http://yucca.test');
  await ctx.db.deleteFrom('futo_backups_config').where('key', '=', ConfigurationKey.Telemetry).execute();
  await ctx.module.get(BackendRepository).updateBackend(REPOSITORY_DEFAULT_CLOUD_UUID, {
    type: BackendType.Yucca,
    accessToken: 'test-token',
  });
});

describe('Telemetry', () => {
  it('does not submit when telemetry consent is absent', async () => {
    const telemetry = ctx.module.get(TelemetryService);

    telemetry.submitStructuredLog('Should be dropped', { repositoryId: 'abc' });
    await delay(50);

    expect(apiSubmitStructuredLog).not.toHaveBeenCalled();
  });

  it('submits to the production backend once consent is granted', async () => {
    await ctx.module.get(ConfigRepository).enableTelemetry();
    const telemetry = ctx.module.get(TelemetryService);

    telemetry.submitStructuredLog('Running backup', { repositoryId: 'abc' });
    await waitFor(() => apiSubmitStructuredLog.mock.calls.length > 0);

    expect(apiSubmitStructuredLog).toHaveBeenCalledTimes(1);
    expect(apiSubmitStructuredLog).toHaveBeenCalledWith(
      {
        summary: 'Running backup',
        data: expect.objectContaining({ repositoryId: 'abc', version: packageJson.version }),
      },
      expect.any(Object),
    );
  });

  it('submits regardless of consent when forced', async () => {
    const telemetry = ctx.module.get(TelemetryService);

    telemetry.submitStructuredLog('Telemetry consent', { consent: 'full' }, true);
    await waitFor(() => apiSubmitStructuredLog.mock.calls.length > 0);

    expect(apiSubmitStructuredLog).toHaveBeenCalledTimes(1);
    expect(apiSubmitStructuredLog).toHaveBeenCalledWith(
      {
        summary: 'Telemetry consent',
        data: expect.objectContaining({ consent: 'full', version: packageJson.version }),
      },
      expect.any(Object),
    );
  });

  it('serialises Error values in the payload', async () => {
    const telemetry = ctx.module.get(TelemetryService);
    const error = new Error('boom');

    telemetry.submitStructuredLog('Backup failed', { repositoryId: 'abc', error }, true);
    await waitFor(() => apiSubmitStructuredLog.mock.calls.length > 0);

    const [{ data }] = apiSubmitStructuredLog.mock.calls[0];
    expect(data.error).toMatchObject({ type: 'Error', message: 'boom' });
    expect(data.error.stack).toEqual(error.stack);
    expect(data.repositoryId).toBe('abc');
  });

  it('does not throw when no production backend is configured', async () => {
    await ctx.db.deleteFrom('futo_backups_backends').where('id', '=', REPOSITORY_DEFAULT_CLOUD_UUID).execute();
    await ctx.module.get(ConfigRepository).enableTelemetry();
    const telemetry = ctx.module.get(TelemetryService);

    expect(() => telemetry.submitStructuredLog('Orphan event', { repositoryId: 'abc' })).not.toThrow();
    await delay(50);

    expect(apiSubmitStructuredLog).not.toHaveBeenCalled();
  });
});
