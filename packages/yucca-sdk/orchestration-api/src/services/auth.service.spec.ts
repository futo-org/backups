import { jest } from '@jest/globals';

jest.unstable_mockModule('@futo-org/backups-api-client', () => import('../../test/mocks/yucca-api-client.js'));

const { getAuth, oidcDeviceAuthorize, oidcDeviceIdentity, oidcDeviceToken } =
  await import('@futo-org/backups-api-client');
const { yuccaWellKnown } = await import('../wellKnown.js');
const { AuthService } = await import('./auth.service.js');

const cloud = { type: 'yucca', accessToken: 'yucca-token', userId: 'owner' };
const requestOptions = { baseUrl: 'https://backups.test' };

const makeService = (configuration?: typeof cloud, requireSession = true) => {
  const backend = { updateBackend: jest.fn(() => Promise.resolve()) };
  const moduleConfig = { get: jest.fn(() => ({ immichIntegration: true, externalBaseUrl: 'https://photos.example' })) };
  const session = {
    cloudConfiguration: jest.fn(() => Promise.resolve(configuration)),
    isRequired: jest.fn(() => requireSession),
    issue: jest.fn(() => Promise.resolve('local-session-token')),
  };

  const service = new AuthService(
    {} as never,
    backend as never,
    moduleConfig as never,
    { publish: jest.fn() } as never,
    { submitStructuredLog: jest.fn() } as never,
    { getAll: jest.fn(() => Promise.resolve([])) } as never,
    session as never,
  );

  return { service, backend };
};

describe(AuthService.name, () => {
  beforeEach(() => {
    jest.spyOn(yuccaWellKnown, 'getBaseUrl').mockResolvedValue(requestOptions.baseUrl);
    jest.mocked(getAuth).mockResolvedValue({ connectionId: null } as never);
  });

  afterEach(() => {
    jest.restoreAllMocks();
    jest.mocked(oidcDeviceAuthorize).mockReset();
    jest.mocked(oidcDeviceIdentity).mockReset();
    jest.mocked(oidcDeviceToken).mockReset();
  });

  describe('authorize', () => {
    it('returns the login started on the FUTO Backups API', async () => {
      const start = {
        deviceCode: 'device-code',
        userCode: 'ABCD',
        verificationUri: 'https://idp.test',
        expiresIn: 300,
      };
      jest.mocked(oidcDeviceAuthorize).mockResolvedValue(start as never);
      const { service } = makeService();

      await expect(service.connectDeviceAuthorize()).resolves.toEqual(start);
      expect(oidcDeviceAuthorize).toHaveBeenCalledWith(requestOptions);
    });

    it('reports an unreachable FUTO Backups API as a bad gateway', async () => {
      jest.mocked(oidcDeviceAuthorize).mockRejectedValue(new Error('unreachable'));
      const { service } = makeService();

      await expect(service.connectDeviceAuthorize()).rejects.toMatchObject({
        status: 502,
        response: expect.objectContaining({ reason: 'UNKNOWN' }),
      });
    });

    it('reports a missing well-known as a bad gateway', async () => {
      jest.spyOn(yuccaWellKnown, 'getBaseUrl').mockRejectedValue(new Error('no well-known'));
      const { service } = makeService();

      await expect(service.connectDeviceAuthorize()).rejects.toMatchObject({ status: 502 });
      expect(oidcDeviceAuthorize).not.toHaveBeenCalled();
    });

    it('refuses a sign in before the instance is connected', async () => {
      const { service } = makeService();

      await expect(service.sessionDeviceAuthorize()).rejects.toMatchObject({
        status: 400,
        response: expect.objectContaining({ reason: 'NOT_CONNECTED' }),
      });
      expect(oidcDeviceAuthorize).not.toHaveBeenCalled();
    });
  });

  describe('token', () => {
    it('reports pending without connecting the backend', async () => {
      jest.mocked(oidcDeviceToken).mockResolvedValue({ status: 'PENDING' } as never);
      const { service, backend } = makeService();

      await expect(service.connectDeviceToken({ deviceCode: 'device-code' })).resolves.toEqual({
        status: 'PENDING',
      });
      expect(backend.updateBackend).not.toHaveBeenCalled();
    });

    it('tells the client to slow down without connecting the backend', async () => {
      jest.mocked(oidcDeviceToken).mockResolvedValue({ status: 'SLOW_DOWN' } as never);
      const { service, backend } = makeService();

      await expect(service.connectDeviceToken({ deviceCode: 'device-code' })).resolves.toEqual({
        status: 'SLOW_DOWN',
      });
      expect(backend.updateBackend).not.toHaveBeenCalled();
    });

    it('fails as unknown when the well-known cannot be read during a poll', async () => {
      jest.spyOn(yuccaWellKnown, 'getBaseUrl').mockRejectedValue(new Error('no well-known'));
      const { service } = makeService();

      await expect(service.connectDeviceToken({ deviceCode: 'device-code' })).resolves.toEqual({
        status: 'FAILURE',
        reason: 'UNKNOWN',
      });
      expect(oidcDeviceToken).not.toHaveBeenCalled();
    });

    it('sends the connection of this instance', async () => {
      jest.mocked(oidcDeviceToken).mockResolvedValue({ status: 'PENDING' } as never);
      const { service } = makeService();

      await service.connectDeviceToken({ deviceCode: 'device-code' });

      expect(oidcDeviceToken).toHaveBeenCalledWith(
        { deviceCode: 'device-code', connectionType: 'immich', connectionName: 'photos.example' },
        requestOptions,
      );
    });

    it('stores the upstream token and returns only the local session token', async () => {
      jest
        .mocked(oidcDeviceToken)
        .mockResolvedValue({ status: 'SUCCESS', accessToken: 'yucca-token', userId: 'user' } as never);
      const { service, backend } = makeService();

      await expect(service.connectDeviceToken({ deviceCode: 'device-code' })).resolves.toEqual({
        status: 'SUCCESS',
        accessToken: 'local-session-token',
        backendId: expect.any(String),
      });
      expect(backend.updateBackend).toHaveBeenCalledWith(
        expect.any(String),
        expect.objectContaining({ accessToken: 'yucca-token', userId: 'user' }),
      );
    });

    it('returns no token when this instance does not require a session', async () => {
      jest
        .mocked(oidcDeviceToken)
        .mockResolvedValue({ status: 'SUCCESS', accessToken: 'yucca-token', userId: 'user' } as never);
      const { service } = makeService(undefined, false);

      await expect(service.connectDeviceToken({ deviceCode: 'device-code' })).resolves.toEqual({
        status: 'SUCCESS',
        accessToken: undefined,
        backendId: expect.any(String),
      });
    });

    it('reports any upstream failure as a failed device flow', async () => {
      jest.mocked(oidcDeviceToken).mockResolvedValue({ status: 'FAILURE', reason: 'ACCESS_DENIED' } as never);
      const { service, backend } = makeService();

      await expect(service.connectDeviceToken({ deviceCode: 'device-code' })).resolves.toEqual({
        status: 'FAILURE',
        reason: 'DEVICE_FLOW_FAILED',
      });
      expect(backend.updateBackend).not.toHaveBeenCalled();
    });

    it('fails as not connected when signing in before the instance is connected', async () => {
      const { service } = makeService();

      await expect(service.sessionDeviceToken({ deviceCode: 'device-code' })).resolves.toEqual({
        status: 'FAILURE',
        reason: 'NOT_CONNECTED',
      });
      expect(oidcDeviceIdentity).not.toHaveBeenCalled();
    });

    it('issues a session when the owner of the instance signs in', async () => {
      jest.mocked(oidcDeviceIdentity).mockResolvedValue({ status: 'SUCCESS', userId: 'owner' } as never);
      const { service } = makeService(cloud);

      await expect(service.sessionDeviceToken({ deviceCode: 'device-code' })).resolves.toEqual({
        status: 'SUCCESS',
        accessToken: 'local-session-token',
      });
      expect(oidcDeviceIdentity).toHaveBeenCalledWith({ deviceCode: 'device-code' }, requestOptions);
    });

    it('fails as wrong account when another user signs in', async () => {
      jest.mocked(oidcDeviceIdentity).mockResolvedValue({ status: 'SUCCESS', userId: 'someone-else' } as never);
      const { service } = makeService(cloud);

      await expect(service.sessionDeviceToken({ deviceCode: 'device-code' })).resolves.toEqual({
        status: 'FAILURE',
        reason: 'WRONG_ACCOUNT',
      });
    });

    it('fails as unknown when an approved connection has no access token', async () => {
      jest.mocked(oidcDeviceToken).mockResolvedValue({ status: 'SUCCESS', userId: 'user' } as never);
      const { service, backend } = makeService();

      await expect(service.connectDeviceToken({ deviceCode: 'device-code' })).resolves.toEqual({
        status: 'FAILURE',
        reason: 'UNKNOWN',
      });
      expect(backend.updateBackend).not.toHaveBeenCalled();
    });

    it('records the owner of an instance that has none before checking the sign in', async () => {
      jest.mocked(oidcDeviceIdentity).mockResolvedValue({ status: 'SUCCESS', userId: 'owner' } as never);
      jest.mocked(getAuth).mockResolvedValue({ id: 'owner' } as never);
      const { service, backend } = makeService({ ...cloud, userId: undefined } as never);

      await expect(service.sessionDeviceToken({ deviceCode: 'device-code' })).resolves.toEqual({
        status: 'SUCCESS',
        accessToken: 'local-session-token',
      });
      expect(backend.updateBackend).toHaveBeenCalledWith(
        expect.any(String),
        expect.objectContaining({ userId: 'owner' }),
      );
    });

    it('reports any upstream failure on a sign in as a failed device flow', async () => {
      jest.mocked(oidcDeviceIdentity).mockResolvedValue({ status: 'FAILURE', reason: 'EXPIRED' } as never);
      const { service } = makeService(cloud);

      await expect(service.sessionDeviceToken({ deviceCode: 'device-code' })).resolves.toEqual({
        status: 'FAILURE',
        reason: 'DEVICE_FLOW_FAILED',
      });
    });

    it('fails as unknown when the FUTO Backups API cannot be reached', async () => {
      jest.mocked(oidcDeviceToken).mockRejectedValue(new Error('unreachable'));
      const { service } = makeService();

      await expect(service.connectDeviceToken({ deviceCode: 'device-code' })).resolves.toEqual({
        status: 'FAILURE',
        reason: 'UNKNOWN',
      });
    });
  });
});
