import type { EmailMessage, EmailRepository as EmailRepositoryType } from '@common/server/email';
import { jest } from '@jest/globals';
import { Mocks, newMocks } from '../../test/mocks.js';

// The repository reads its env when imported, so set it before loading it.
process.env.RESEND_API_URL = 'https://resend.test';
process.env.RESEND_API_KEY = 're_test';
const { EmailRepository } = await import('@common/server/email');

const message = (to: string): EmailMessage => ({
  to,
  subject: 'Your invite',
  htmlBody: '<p>hi</p>',
  textBody: 'hi',
  tag: 'invite',
});

const json = (status: number, body: unknown) => Response.json(body, { status });

describe('EmailRepository', () => {
  let mocks: Mocks;
  let sut: EmailRepositoryType;
  let fetchMock: jest.Mock<typeof fetch>;

  beforeEach(() => {
    mocks = newMocks();
    sut = new EmailRepository(mocks.logger as never);
    fetchMock = jest.fn<typeof fetch>();
    globalThis.fetch = fetchMock;
  });

  const calls = () =>
    fetchMock.mock.calls.map(([url, init]) => ({
      url: `${url as URL}`,
      headers: init?.headers as Record<string, string>,
      body: JSON.parse(init?.body as string) as unknown,
    }));

  describe('send', () => {
    it('posts one email to Resend with the bearer key', async () => {
      fetchMock.mockResolvedValue(json(200, { id: 'email-1' }));

      await sut.send(message('user@example.com'));

      expect(calls()).toEqual([
        {
          url: 'https://resend.test/emails',
          headers: expect.objectContaining({ Authorization: 'Bearer re_test' }),
          body: {
            from: 'FUTO Backups <noreply@backups.futo.cloud>',
            to: ['user@example.com'],
            subject: 'Your invite',
            html: '<p>hi</p>',
            text: 'hi',
            tags: [{ name: 'category', value: 'invite' }],
          },
        },
      ]);
    });

    it('throws when Resend rejects the email', async () => {
      fetchMock.mockResolvedValue(json(422, { statusCode: 422, name: 'validation_error', message: 'bad to' }));

      await expect(sut.send(message('nope'))).rejects.toThrow('Resend /emails failed: 422');
    });
  });

  describe('sendBatch', () => {
    it('maps each queued email id back to its recipient', async () => {
      fetchMock.mockResolvedValue(json(200, { data: [{ id: 'email-1' }, { id: 'email-2' }] }));

      const results = await sut.sendBatch([message('a@example.com'), message('b@example.com')]);

      expect(calls()[0]?.url).toBe('https://resend.test/emails/batch');
      expect(results).toEqual([
        { to: 'a@example.com', errorCode: 0, message: 'email-1' },
        { to: 'b@example.com', errorCode: 0, message: 'email-2' },
      ]);
    });

    it('sends at most 100 emails per batch', async () => {
      fetchMock.mockImplementation((_url, init) => {
        const body = JSON.parse(init?.body as string) as unknown[];
        return Promise.resolve(json(200, { data: body.map((_, i) => ({ id: `email-${i}` })) }));
      });

      const results = await sut.sendBatch(Array.from({ length: 101 }, (_, i) => message(`user${i}@example.com`)));

      expect(calls().map(({ body }) => (body as unknown[]).length)).toEqual([100, 1]);
      expect(results).toHaveLength(101);
      expect(results.every((result) => result.errorCode === 0)).toBe(true);
    });

    it('keeps earlier chunks sent when a later chunk is rejected', async () => {
      fetchMock
        .mockResolvedValueOnce(json(200, { data: Array.from({ length: 100 }, (_, i) => ({ id: `email-${i}` })) }))
        .mockResolvedValueOnce(json(422, { statusCode: 422, name: 'validation_error', message: 'bad to' }));

      const results = await sut.sendBatch(Array.from({ length: 101 }, (_, i) => message(`user${i}@example.com`)));

      expect(results.slice(0, 100).every((result) => result.errorCode === 0)).toBe(true);
      expect(results[100]).toEqual(
        expect.objectContaining({ to: 'user100@example.com', errorCode: 422, message: expect.stringContaining('422') }),
      );
      expect(mocks.logger.error).toHaveBeenCalledTimes(1);
    });
  });
});
