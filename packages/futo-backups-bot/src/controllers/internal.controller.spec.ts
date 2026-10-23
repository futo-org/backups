import { jest } from '@jest/globals';
import { INestApplication, NotFoundException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { env } from 'src/env.js';
import { InviteService } from 'src/services/invite.service.js';
import { SupportService } from 'src/services/support.service.js';
import { TicketContext } from 'src/utils/ticketContext.js';
import { InternalController } from './internal.controller.js';

const context: TicketContext = {
  ticketThreadId: '123456789012345678',
  discordUserId: '234567890123456789',
  closed: false,
  messages: [
    {
      id: '345678901234567890',
      authorId: '234567890123456789',
      username: 'Customer',
      content: 'See the error image',
      createdAt: '2026-10-22T12:00:00.000Z',
      attachments: [
        { id: '456789012345678901', name: 'error.png', url: 'https://cdn.discordapp.com/error.png', size: 42 },
      ],
    },
  ],
};

describe(InternalController.name, () => {
  let app: INestApplication;
  let baseUrl: string;
  const getTicketContext = jest.fn<SupportService['getTicketContext']>();
  const originalSecret = env.INTERNAL_SECRET;

  beforeAll(async () => {
    env.INTERNAL_SECRET = 'context-test-secret';
    const module = await Test.createTestingModule({
      controllers: [InternalController],
      providers: [
        { provide: InviteService, useValue: {} },
        { provide: SupportService, useValue: { getTicketContext } },
      ],
    }).compile();
    app = module.createNestApplication();
    await app.listen(0, '127.0.0.1');
    baseUrl = await app.getUrl();
  });

  beforeEach(() => {
    getTicketContext.mockReset().mockResolvedValue(context);
  });

  afterAll(async () => {
    await app.close();
    env.INTERNAL_SECRET = originalSecret;
  });

  it.each([undefined, 'incorrect'])('requires the internal secret before reading messages (%s)', async (secret) => {
    const response = await fetch(`${baseUrl}/internal/tickets/${context.ticketThreadId}/context`, {
      headers: secret ? { 'X-Internal-Secret': secret } : {},
    });

    expect(response.status).toBe(401);
    expect(getTicketContext).not.toHaveBeenCalled();
  });

  it('returns the canonical ticket context through the guarded Nest pipeline', async () => {
    const response = await fetch(`${baseUrl}/internal/tickets/${context.ticketThreadId}/context`, {
      headers: { 'X-Internal-Secret': env.INTERNAL_SECRET },
    });

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual(context);
    expect(getTicketContext).toHaveBeenCalledWith(context.ticketThreadId);
  });

  it.each(['invalid', '123', '1'.repeat(21)])(
    'hides invalid thread ids with the same not-found response (%s)',
    async (id) => {
      const response = await fetch(`${baseUrl}/internal/tickets/${id}/context`, {
        headers: { 'X-Internal-Secret': env.INTERNAL_SECRET },
      });

      expect(response.status).toBe(404);
      await expect(response.json()).resolves.toEqual(expect.objectContaining({ message: 'Ticket not found' }));
      expect(getTicketContext).not.toHaveBeenCalled();
    },
  );

  it('returns the same not-found response for missing or inaccessible tickets', async () => {
    getTicketContext.mockRejectedValueOnce(new NotFoundException('Ticket not found'));

    const response = await fetch(`${baseUrl}/internal/tickets/${context.ticketThreadId}/context`, {
      headers: { 'X-Internal-Secret': env.INTERNAL_SECRET },
    });

    expect(response.status).toBe(404);
    await expect(response.json()).resolves.toEqual(expect.objectContaining({ message: 'Ticket not found' }));
  });
});
