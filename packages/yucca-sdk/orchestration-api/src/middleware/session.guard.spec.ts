import { jest } from '@jest/globals';
import { ExecutionContext, UnauthorizedException } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { SessionService } from '../services/session.service.js';
import { SessionGuard } from './session.guard.js';

class HostController {
  handle() {}
}

const context = {
  getHandler: () => HostController.prototype.handle,
  getClass: () => HostController,
  switchToHttp: () => ({ getRequest: () => ({ headers: {} }) }),
} as unknown as ExecutionContext;

const makeGuard = (moduleConfig: { requireSession?: boolean }) => {
  const config = { getSessionSecret: jest.fn().mockResolvedValue(Buffer.alloc(32, 1)) };
  const backend = {
    getBackend: jest.fn().mockResolvedValue({ configuration: { type: 'yucca', userId: 'user' } }),
  };
  const session = new SessionService(
    config as never,
    { get: () => moduleConfig } as never,
    backend as never,
    new JwtService(),
  );

  return { guard: new SessionGuard(new Reflector(), session), backend };
};

describe(SessionGuard.name, () => {
  it('lets the request through without reading the database when the host turns sessions off', async () => {
    const { guard, backend } = makeGuard({ requireSession: false });

    await expect(guard.canActivate(context)).resolves.toBe(true);
    expect(backend.getBackend).not.toHaveBeenCalled();
  });

  it('lets the request through without reading the database when the host does not set requireSession', async () => {
    const { guard, backend } = makeGuard({});

    await expect(guard.canActivate(context)).resolves.toBe(true);
    expect(backend.getBackend).not.toHaveBeenCalled();
  });

  it('rejects a request without a session when the host requires one', async () => {
    const { guard } = makeGuard({ requireSession: true });

    await expect(guard.canActivate(context)).rejects.toThrow(UnauthorizedException);
  });
});
