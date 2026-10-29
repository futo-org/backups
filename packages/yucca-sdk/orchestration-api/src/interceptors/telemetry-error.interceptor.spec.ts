import { jest } from '@jest/globals';
import { Controller, ExecutionContext } from '@nestjs/common';
import { lastValueFrom, throwError } from 'rxjs';
import { JobController } from '../controllers/job.controller.js';
import { TelemetryErrorInterceptor } from './telemetry-error.interceptor.js';

@Controller('/host/assets')
class HostController {}

const failRequest = async (controller: object) => {
  const telemetry = { submitStructuredLog: jest.fn() };
  const interceptor = new TelemetryErrorInterceptor(telemetry as never);
  const context = {
    getClass: () => controller,
    switchToHttp: () => ({ getRequest: () => ({ method: 'GET', url: '/api/futo-backups/jobs' }) }),
  } as unknown as ExecutionContext;
  const next = { handle: () => throwError(() => new Error('boom')) };

  await expect(lastValueFrom(interceptor.intercept(context, next))).rejects.toThrow('boom');

  return telemetry.submitStructuredLog;
};

describe(TelemetryErrorInterceptor.name, () => {
  it('reports server errors from futo-backups routes', async () => {
    const submitStructuredLog = await failRequest(JobController);

    expect(submitStructuredLog).toHaveBeenCalledWith(
      'Unhandled request error',
      expect.objectContaining({ method: 'GET', path: '/api/futo-backups/jobs' }),
    );
  });

  it('ignores errors from routes the host application owns', async () => {
    const submitStructuredLog = await failRequest(HostController);

    expect(submitStructuredLog).not.toHaveBeenCalled();
  });
});
