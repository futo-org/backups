import { isoDatetimeToDate } from '@common/server';
import { createZodDto } from 'nestjs-zod';
import { z } from 'zod';

const SupportLogSessionAdminSchema = z
  .object({
    id: z.string().describe('The support code shown to the user; search VictoriaLogs for support_session:<id>'),
    userId: z.string(),
    connectionId: z.string().nullable(),
    jobId: z.string(),
    jobName: z.string(),
    includesPaths: z.boolean(),
    clientVersion: z.string().nullable(),
    lineCount: z.number(),
    byteCount: z.number(),
    batchCount: z.number(),
    droppedLineCount: z.number(),
    createdAt: isoDatetimeToDate,
    lastBatchAt: isoDatetimeToDate.nullable(),
    finishedAt: isoDatetimeToDate.nullable(),
  })
  .meta({ id: 'SupportLogSessionAdminDto' });

const SupportLogSessionListResponseSchema = z
  .object({ sessions: z.array(SupportLogSessionAdminSchema) })
  .meta({ id: 'SupportLogSessionListResponseDto' });

export class SupportLogSessionAdminDto extends createZodDto(SupportLogSessionAdminSchema) {}
export class SupportLogSessionListResponseDto extends createZodDto(SupportLogSessionListResponseSchema) {}
