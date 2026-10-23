import { jest } from '@jest/globals';
import { FreshdeskRepository } from 'src/repositories/freshdesk.repository.js';

const attachmentLimit = 18 * 1024 * 1024;
const imageStub = { name: 'screenshot.png', url: 'https://cdn.discord.test/screenshot.png' };

describe(FreshdeskRepository.name, () => {
  let sut: FreshdeskRepository;
  let mocks: { fetch: jest.SpiedFunction<typeof fetch>; logger: { warn: ReturnType<typeof jest.fn> } };

  beforeEach(() => {
    mocks = { fetch: jest.spyOn(globalThis, 'fetch'), logger: { warn: jest.fn() } };
    sut = new FreshdeskRepository(mocks.logger as never);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  describe('createNote', () => {
    it('uploads image bytes and captions with the note visibility fields', async () => {
      mocks.fetch
        .mockResolvedValueOnce(
          new Response(Uint8Array.from([137, 80, 78, 71]), { headers: { 'Content-Type': 'image/png' } }),
        )
        .mockResolvedValueOnce(
          new Response(Uint8Array.from([255, 216, 255]), { headers: { 'Content-Type': 'image/jpeg' } }),
        )
        .mockResolvedValueOnce(new Response('{}', { status: 201 }));

      await sut.createNote('42', '<b>Customer</b><br>This is the error', { private: false, incoming: true }, [
        imageStub,
        { name: 'photo.jpg', url: 'https://cdn.discord.test/photo.jpg' },
      ]);

      const ctx = {
        request: mocks.fetch.mock.calls[2],
        form: mocks.fetch.mock.calls[2][1]?.body as FormData,
      };
      expect(String(ctx.request[0])).toBe('https://example.freshdesk.test/api/v2/tickets/42/notes');
      expect(ctx.request[1]).toEqual({
        method: 'POST',
        headers: { Authorization: `Basic ${Buffer.from('test-key:X').toString('base64')}` },
        body: expect.any(FormData),
      });
      expect(ctx.form.get('body')).toBe('<b>Customer</b><br>This is the error');
      expect(ctx.form.get('private')).toBe('false');
      expect(ctx.form.get('incoming')).toBe('true');
      expect(ctx.form.getAll('attachments[]')).toHaveLength(2);
      expect(ctx.form.getAll('attachments[]').map((file) => (file as File).name)).toEqual([
        'screenshot.png',
        'photo.jpg',
      ]);
      expect(ctx.form.getAll('attachments[]').map((file) => (file as File).type)).toEqual(['image/png', 'image/jpeg']);
      expect(
        await Promise.all(
          ctx.form.getAll('attachments[]').map(async (file) => [...new Uint8Array(await (file as File).arrayBuffer())]),
        ),
      ).toEqual([
        [137, 80, 78, 71],
        [255, 216, 255],
      ]);
      expect(mocks.fetch.mock.calls[0][1]).not.toHaveProperty('headers');
    });

    it('uses JSON when there are no attachments', async () => {
      mocks.fetch.mockResolvedValueOnce(new Response('{}', { status: 201 }));

      await sut.createNote('42', 'Account details', { private: true });

      expect(mocks.fetch).toHaveBeenCalledTimes(1);
      expect(mocks.fetch).toHaveBeenCalledWith(new URL('https://example.freshdesk.test/api/v2/tickets/42/notes'), {
        method: 'POST',
        headers: {
          Authorization: `Basic ${Buffer.from('test-key:X').toString('base64')}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ body: 'Account details', private: true, incoming: false }),
      });
    });

    it('preserves empty attachments', async () => {
      mocks.fetch.mockResolvedValueOnce(new Response(null)).mockResolvedValueOnce(new Response('{}', { status: 201 }));

      await sut.createNote('42', 'Empty file', { private: true }, [imageStub]);

      const ctx = { form: mocks.fetch.mock.calls[1][1]?.body as FormData };
      expect(ctx.form.getAll('attachments[]')).toHaveLength(1);
      expect((ctx.form.get('attachments[]') as File).size).toBe(0);
    });

    it('rejects failed downloads before posting a note so the sync can retry', async () => {
      const ctx = { error: new TypeError('fetch failed') };
      mocks.fetch.mockRejectedValueOnce(ctx.error);

      await expect(sut.createNote('42', 'Error screenshot', { private: false }, [imageStub])).rejects.toBe(ctx.error);

      expect(mocks.fetch).toHaveBeenCalledTimes(1);
      expect(mocks.logger.warn).toHaveBeenCalledWith(ctx.error, 'failed to download attachment screenshot.png');
    });

    it.each([403, 500])('rejects an attachment download with HTTP status %s', async (status) => {
      mocks.fetch.mockResolvedValueOnce(new Response('Download failed', { status }));

      await expect(sut.createNote('42', 'Error screenshot', { private: false }, [imageStub])).rejects.toThrow(
        `${status}`,
      );

      expect(mocks.fetch).toHaveBeenCalledTimes(1);
    });

    it('does not post a partial note when a later attachment download fails', async () => {
      mocks.fetch
        .mockResolvedValueOnce(new Response('first image'))
        .mockRejectedValueOnce(new TypeError('fetch failed'));

      await expect(
        sut.createNote('42', 'Two screenshots', { private: true }, [
          imageStub,
          { name: 'second.png', url: 'https://cdn.discord.test/second.png' },
        ]),
      ).rejects.toBeInstanceOf(TypeError);

      expect(mocks.fetch).toHaveBeenCalledTimes(2);
    });

    it('rejects interrupted download streams without posting a partial image', async () => {
      const ctx = { error: new TypeError('connection interrupted') };
      mocks.fetch.mockResolvedValueOnce(
        new Response(
          new ReadableStream({
            start(controller) {
              controller.error(ctx.error);
            },
          }),
        ),
      );

      await expect(sut.createNote('42', 'Error screenshot', { private: true }, [imageStub])).rejects.toBe(ctx.error);

      expect(mocks.fetch).toHaveBeenCalledTimes(1);
    });

    it('omits oversized attachments before reading their body and escapes their filenames', async () => {
      const ctx = { cancel: jest.fn<() => void>() };
      mocks.fetch
        .mockResolvedValueOnce(
          new Response(new ReadableStream({ cancel: () => ctx.cancel() }), {
            headers: { 'Content-Length': String(attachmentLimit + 1) },
          }),
        )
        .mockResolvedValueOnce(new Response('{}', { status: 201 }));

      await sut.createNote('42', 'Error screenshot', { private: false }, [{ ...imageStub, name: '<screenshot>.png' }]);

      expect(ctx.cancel).toHaveBeenCalledTimes(1);
      expect(JSON.parse(String(mocks.fetch.mock.calls[1][1]?.body))).toEqual({
        body: 'Error screenshot<br><i>Attachment omitted (too large): &lt;screenshot&gt;.png</i>',
        private: false,
        incoming: false,
      });
    });

    it.each([undefined, '1'])(
      'stops streaming attachments exceeding the limit with Content-Length %s',
      async (length) => {
        const ctx = { cancel: jest.fn<() => void>() };
        mocks.fetch
          .mockResolvedValueOnce(
            new Response(
              new ReadableStream({
                start(controller) {
                  controller.enqueue(new Uint8Array(attachmentLimit));
                  controller.enqueue(new Uint8Array(1));
                },
                cancel: () => ctx.cancel(),
              }),
              { headers: length ? { 'Content-Length': length } : {} },
            ),
          )
          .mockResolvedValueOnce(new Response('{}', { status: 201 }));

        await sut.createNote('42', 'Error screenshot', { private: true }, [imageStub]);

        expect(ctx.cancel).toHaveBeenCalledTimes(1);
        expect(JSON.parse(String(mocks.fetch.mock.calls[1][1]?.body))).toEqual({
          body: 'Error screenshot<br><i>Attachment omitted (too large): screenshot.png</i>',
          private: true,
          incoming: false,
        });
      },
    );

    it('keeps attachments that fit the remaining total budget after omitting a larger one', async () => {
      mocks.fetch
        .mockResolvedValueOnce(new Response(new Uint8Array(attachmentLimit - 1)))
        .mockResolvedValueOnce(new Response('too large', { headers: { 'Content-Length': '2' } }))
        .mockResolvedValueOnce(new Response(Uint8Array.from([5])))
        .mockResolvedValueOnce(new Response('{}', { status: 201 }));

      await sut.createNote('42', 'Screenshots', { private: true }, [
        imageStub,
        { name: 'large.png', url: 'https://cdn.discord.test/large.png' },
        { name: 'small.png', url: 'https://cdn.discord.test/small.png' },
      ]);

      const ctx = { form: mocks.fetch.mock.calls[3][1]?.body as FormData };
      expect(ctx.form.get('body')).toBe('Screenshots<br><i>Attachment omitted (too large): large.png</i>');
      expect(ctx.form.getAll('attachments[]').map((file) => (file as File).name)).toEqual([
        'screenshot.png',
        'small.png',
      ]);
      expect(ctx.form.getAll('attachments[]').map((file) => (file as File).size)).toEqual([attachmentLimit - 1, 1]);
    });

    it('rejects failed Freshdesk uploads so the sync can retry', async () => {
      mocks.fetch
        .mockResolvedValueOnce(new Response('image'))
        .mockResolvedValueOnce(new Response('Unavailable', { status: 503 }));

      await expect(sut.createNote('42', 'Error screenshot', { private: false }, [imageStub])).rejects.toThrow(
        'freshdesk POST /api/v2/tickets/42/notes failed: 503',
      );

      expect(mocks.fetch).toHaveBeenCalledTimes(2);
    });
  });

  describe('createReply', () => {
    it('uploads an image-only reply with a nonempty body', async () => {
      mocks.fetch
        .mockResolvedValueOnce(
          new Response(Uint8Array.from([137, 80, 78, 71]), { headers: { 'Content-Type': 'image/png' } }),
        )
        .mockResolvedValueOnce(new Response('{}', { status: 201 }));

      await sut.createReply('42', '', [imageStub]);

      const ctx = { form: mocks.fetch.mock.calls[1][1]?.body as FormData };
      expect(String(mocks.fetch.mock.calls[1][0])).toBe('https://example.freshdesk.test/api/v2/tickets/42/reply');
      expect(ctx.form.get('body')).toBe('Attachments');
      expect(ctx.form.has('private')).toBe(false);
      expect(ctx.form.has('incoming')).toBe(false);
      expect(ctx.form.getAll('attachments[]')).toHaveLength(1);
    });
  });
});
