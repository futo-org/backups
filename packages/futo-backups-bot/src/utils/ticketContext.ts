import { Message } from 'discord.js';
import { Messages } from 'src/messages.js';

export const TICKET_CONTEXT_MESSAGE_LIMIT = 50;
export const TICKET_CONTEXT_MAX_BYTES = 240 * 1024;
const CONTENT_MAX_BYTES = 16 * 1024;
const USERNAME_MAX_BYTES = 256;
const ATTACHMENT_NAME_MAX_BYTES = 1024;
const ATTACHMENT_URL_MAX_BYTES = 4096;
const ATTACHMENT_TYPE_MAX_BYTES = 256;
const ATTACHMENT_LIMIT = 10;

export type TicketAttachment = {
  id: string;
  name: string;
  url: string;
  contentType?: string;
  size: number;
};

export type TicketMessage = {
  id: string;
  authorId: string;
  username: string;
  content: string;
  createdAt: string;
  attachments: TicketAttachment[];
};

export type TicketContext = {
  ticketThreadId: string;
  discordUserId: string;
  closed: boolean;
  messages: TicketMessage[];
};

export const mapTicketMessages = (messages: Message[], ownBotId: string): TicketMessage[] => {
  return messages
    .flatMap((message) => {
      const mirrors =
        message.author.id === ownBotId
          ? message.embeds.filter(
              (embed) =>
                embed.author?.name === Messages.viaEmailAuthor || embed.author?.name.endsWith('(FUTO support)'),
            )
          : [];
      if (message.author.bot && mirrors.length === 0) {
        return [];
      }
      const content = [message.content, ...mirrors.map((embed) => embed.description ?? '')].filter(Boolean).join('\n');
      const attachments = [...message.attachments.values()]
        .filter(
          (attachment) =>
            Buffer.byteLength(attachment.url) <= ATTACHMENT_URL_MAX_BYTES &&
            Number.isSafeInteger(attachment.size) &&
            attachment.size >= 0,
        )
        .slice(0, ATTACHMENT_LIMIT)
        .map((attachment): TicketAttachment => ({
          id: attachment.id,
          name: limitText(attachment.name, ATTACHMENT_NAME_MAX_BYTES),
          url: attachment.url,
          ...(attachment.contentType
            ? { contentType: limitText(attachment.contentType, ATTACHMENT_TYPE_MAX_BYTES) }
            : {}),
          size: attachment.size,
        }));
      return [
        {
          id: message.id,
          authorId: message.author.id,
          username: limitText(mirrors[0]?.author?.name ?? message.author.username, USERNAME_MAX_BYTES),
          content: limitText(content, CONTENT_MAX_BYTES),
          createdAt: message.createdAt.toISOString(),
          attachments,
        },
      ];
    })
    .toSorted((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt))
    .slice(-TICKET_CONTEXT_MESSAGE_LIMIT);
};

export const boundTicketContext = (context: TicketContext): TicketContext => {
  const result = { ...context, messages: [...context.messages] };
  while (Buffer.byteLength(JSON.stringify(result)) > TICKET_CONTEXT_MAX_BYTES && result.messages.length > 0) {
    result.messages.shift();
  }
  return result;
};

const limitText = (value: string, limit: number): string => {
  const bytes = Buffer.from(value);
  if (bytes.length <= limit) {
    return value;
  }
  let end = limit;
  while ((bytes[end] & 0xc0) === 0x80) {
    end--;
  }
  return bytes.subarray(0, end).toString();
};
