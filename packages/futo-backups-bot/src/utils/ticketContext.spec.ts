import { Message } from 'discord.js';
import { Messages } from 'src/messages.js';
import { TICKET_CONTEXT_MAX_BYTES, boundTicketContext, mapTicketMessages } from './ticketContext.js';

const newMessage = (overrides: object = {}): Message =>
  ({
    id: 'message-1',
    author: { id: 'customer-1', username: 'Customer', bot: false },
    content: 'Restore failed',
    createdAt: new Date('2026-10-22T12:00:00Z'),
    embeds: [],
    attachments: new Map(),
    ...overrides,
  }) as never;

describe('ticket context', () => {
  it('includes human follow-ups and attached files in the canonical shape', () => {
    const result = mapTicketMessages(
      [
        newMessage({
          attachments: new Map([
            [
              'file-1',
              {
                id: 'file-1',
                name: 'error.png',
                url: 'https://cdn.discordapp.com/error.png',
                contentType: 'image/png',
                size: 123,
              },
            ],
          ]),
        }),
      ],
      'own-bot',
    );

    expect(result).toEqual([
      {
        id: 'message-1',
        authorId: 'customer-1',
        username: 'Customer',
        content: 'Restore failed',
        createdAt: '2026-10-22T12:00:00.000Z',
        attachments: [
          {
            id: 'file-1',
            name: 'error.png',
            url: 'https://cdn.discordapp.com/error.png',
            contentType: 'image/png',
            size: 123,
          },
        ],
      },
    ]);
  });

  it('includes Freshdesk mirrors only when authored by our own bot', () => {
    const mirror = { author: { name: Messages.viaEmailAuthor }, description: 'Customer email evidence' };
    const support = { author: { name: 'Agent (FUTO support)' }, description: 'Please retry the restore' };
    const result = mapTicketMessages(
      [
        newMessage({
          id: 'email',
          author: { id: 'own-bot', username: 'Support', bot: true },
          content: '',
          embeds: [mirror],
        }),
        newMessage({
          id: 'reply',
          author: { id: 'own-bot', username: 'Support', bot: true },
          content: '',
          embeds: [support],
        }),
        newMessage({ id: 'forged', author: { id: 'another-bot', bot: true }, embeds: [mirror] }),
        newMessage({ id: 'ai-note', author: { id: 'own-bot', bot: true }, content: 'Previous AI investigation' }),
      ],
      'own-bot',
    );

    expect(result.map(({ id }) => id)).toEqual(['email', 'reply']);
    expect(result[0]).toEqual(
      expect.objectContaining({ username: Messages.viaEmailAuthor, content: 'Customer email evidence' }),
    );
    expect(result[1].content).toBe('Please retry the restore');
  });

  it('keeps the latest fifty eligible messages in chronological order', () => {
    const result = mapTicketMessages(
      Array.from({ length: 80 }, (_, i) =>
        newMessage({ id: `message-${i}`, createdAt: new Date(i * 1000) }),
      ).toReversed(),
      'own-bot',
    );

    expect(result).toHaveLength(50);
    expect(result[0].id).toBe('message-30');
    expect(result.at(-1)?.id).toBe('message-79');
  });

  it('bounds large unicode content and total JSON bytes while retaining the newest evidence', () => {
    const messages = mapTicketMessages(
      Array.from({ length: 50 }, (_, i) =>
        newMessage({
          id: `message-${i}`,
          content: '界'.repeat(20_000),
          createdAt: new Date(i * 1000),
        }),
      ),
      'own-bot',
    );
    const result = boundTicketContext({
      ticketThreadId: 'ticket-1',
      discordUserId: 'customer-1',
      closed: false,
      messages,
    });

    expect(Buffer.byteLength(JSON.stringify(result))).toBeLessThanOrEqual(TICKET_CONTEXT_MAX_BYTES);
    expect(result.messages.length).toBeLessThan(50);
    expect(result.messages.length).toBeGreaterThan(0);
    expect(result.messages.at(-1)?.id).toBe('message-49');
    expect(
      result.messages.every(({ content }) => Buffer.byteLength(content) <= 16 * 1024 && !content.includes('�')),
    ).toBe(true);
    expect(messages).toHaveLength(50);
  });
});
