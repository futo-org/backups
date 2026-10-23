import { Injectable } from '@nestjs/common';
import z from 'zod';
import { LoggerRepository } from '../otel/logger.repository.js';
import { emailEnv } from './env.js';

export interface EmailMessage {
  to: string;
  subject: string;
  htmlBody: string;
  textBody: string;
  tag?: string;
}

export interface EmailSendResult {
  to: string;
  errorCode: number;
  message: string;
}

const sendResponseSchema = z.object({ id: z.string() });
const batchResponseSchema = z.object({ data: z.array(sendResponseSchema) });

// Resend accepts at most 100 emails per batch, and rejects or accepts a batch
// as a whole: a 2xx means every email in it was queued.
const BATCH_LIMIT = 100;

class ResendError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

@Injectable()
export class EmailRepository {
  constructor(private logger: LoggerRepository) {}

  async send(message: EmailMessage): Promise<void> {
    if (!emailEnv.RESEND_API_KEY) {
      this.logSkipped([message]);
      return;
    }

    sendResponseSchema.parse(await this.request('/emails', toResendMessage(message)));
  }

  async sendBatch(messages: EmailMessage[]): Promise<EmailSendResult[]> {
    if (messages.length === 0) {
      return [];
    }

    if (!emailEnv.RESEND_API_KEY) {
      this.logSkipped(messages);
      return messages.map((message) => ({ to: message.to, errorCode: 0, message: 'Email sending disabled' }));
    }

    const results: EmailSendResult[] = [];
    for (let offset = 0; offset < messages.length; offset += BATCH_LIMIT) {
      const chunk = messages.slice(offset, offset + BATCH_LIMIT);
      try {
        const { data } = batchResponseSchema.parse(
          await this.request(
            '/emails/batch',
            chunk.map((message) => toResendMessage(message)),
          ),
        );
        if (data.length !== chunk.length) {
          throw new Error(`Resend queued ${data.length} of ${chunk.length} batched emails`);
        }
        results.push(...chunk.map((message, i) => ({ to: message.to, errorCode: 0, message: data[i]!.id })));
      } catch (error) {
        // Earlier chunks are already queued: report only this chunk as failed
        // rather than throwing their results away, so a retry doesn't resend them.
        this.logger.error(error, `Resend rejected a batch of ${chunk.length} emails`);
        const errorCode = error instanceof ResendError ? error.status : 1;
        results.push(...chunk.map((message) => ({ to: message.to, errorCode, message: `${error}` })));
      }
    }
    return results;
  }

  private logSkipped(messages: EmailMessage[]): void {
    this.logger.info(
      { to: messages.map((message) => message.to), subject: messages[0]?.subject },
      'RESEND_API_KEY is not set — skipping email send',
    );
  }

  private async request(path: string, body: unknown): Promise<unknown> {
    const response = await fetch(new URL(path, emailEnv.RESEND_API_URL), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
        Authorization: `Bearer ${emailEnv.RESEND_API_KEY!}`,
      },
      body: JSON.stringify(body),
    });
    if (!response.ok) {
      throw new ResendError(
        response.status,
        `Resend ${path} failed: ${response.status} ${response.statusText} — ${await response.text()}`,
      );
    }
    return response.json();
  }
}

const toResendMessage = (message: EmailMessage) => ({
  from: emailEnv.EMAIL_FROM_ADDRESS,
  to: [message.to],
  subject: message.subject,
  html: message.htmlBody,
  text: message.textBody,
  ...(message.tag === undefined ? {} : { tags: [{ name: 'category', value: message.tag }] }),
});
