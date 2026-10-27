import { isoDatetimeToDate } from '@common/server';
import { createZodDto } from 'nestjs-zod';
import { z } from 'zod';

const SupportLogSessionCreateRequestSchema = z
  .object({
    jobId: z.string().min(1).max(64),
    jobName: z.string().min(1).max(64),
    includesPaths: z.boolean().describe('Whether the streamed lines carry file paths or redacted placeholders'),
    clientVersion: z.string().max(64).optional(),
  })
  .meta({ id: 'SupportLogSessionCreateRequestDto' });

const SupportLogSessionTokenSchema = z
  .object({
    id: z.uuid(),
    token: z.string().describe('Bearer token for the support-logs streamer, bound to this session'),
    url: z.url().describe('Where to POST the session’s log batches'),
    expiresAt: isoDatetimeToDate,
  })
  .meta({ id: 'SupportLogSessionTokenDto' });

const SupportLogSessionStatsRequestSchema = z.object({
  reportId: z.uuid(),
  lines: z.int().min(0),
  bytes: z.int().min(0),
  batches: z.int().min(0),
  droppedLines: z.int().min(0),
  lastBatchAt: z.iso.datetime({ offset: true }).optional(),
  finished: z.boolean().default(false),
});

export class SupportLogSessionCreateRequestDto extends createZodDto(SupportLogSessionCreateRequestSchema) {}
export class SupportLogSessionTokenDto extends createZodDto(SupportLogSessionTokenSchema, { codec: true }) {}
export class SupportLogSessionStatsRequestDto extends createZodDto(SupportLogSessionStatsRequestSchema) {}
