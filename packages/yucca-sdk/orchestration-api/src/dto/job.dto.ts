import { createZodDto } from 'nestjs-zod';
import { z } from 'zod';
import { JobName, JobStatus } from '../enum.js';

const JobSummarySchema = z
  .discriminatedUnion('type', [
    z.object({
      type: z.literal('backup'),
      filesNew: z.number(),
      filesChanged: z.number(),
      totalFilesProcessed: z.number(),
      totalBytesProcessed: z.number(),
      snapshotId: z.string().optional(),
    }),
    z.object({
      type: z.literal('restore'),
      filesRestored: z.number(),
      filesSkipped: z.number(),
      bytesRestored: z.number(),
    }),
    z.object({
      type: z.literal('prune'),
      kept: z.number(),
      removed: z.number(),
    }),
  ])
  .meta({ id: 'JobSummaryDto' });

const JobProgressSchema = z
  .object({
    percentDone: z.number(),
    secondsRemaining: z.number().optional(),
    bytesDone: z.number().optional(),
    totalBytes: z.number().optional(),
    currentFiles: z.array(z.string()),
  })
  .meta({ id: 'JobProgressDto' });

const JobOutcomeSchema = z
  .object({
    errors: z.array(z.string()),
    summary: JobSummarySchema.optional(),
    support: z
      .object({
        sessionId: z.string().optional().describe('Support code to share with FUTO when the logs were streamed'),
        droppedLines: z.number().describe('Log lines that could not be streamed in time'),
        localDroppedLines: z.number().describe('Log lines that could not be written to the local support log'),
      })
      .optional()
      .meta({ id: 'JobSupportDto' }),
  })
  .meta({ id: 'JobOutcomeDto' });

export const JobSchema = z
  .object({
    id: z.string(),
    name: z.enum(JobName).meta({ id: 'JobName' }),
    repositoryId: z.string(),
    status: z.enum(JobStatus).meta({ id: 'JobStatus' }),
    queuedAt: z.string(),
    start: z.string().optional(),
    end: z.string().optional(),
    progress: JobProgressSchema.optional(),
    outcome: JobOutcomeSchema.optional(),
  })
  .meta({ id: 'JobDto' });

const JobListResponseSchema = z.object({ jobs: z.array(JobSchema) }).meta({ id: 'JobListResponseDto' });

const JobListRequestSchema = z.object({ repositoryId: z.string() }).meta({ id: 'JobListRequestDto' });

export class JobDto extends createZodDto(JobSchema) {}
export class JobProgressDto extends createZodDto(JobProgressSchema) {}
export class JobOutcomeDto extends createZodDto(JobOutcomeSchema) {}
export class JobListResponseDto extends createZodDto(JobListResponseSchema) {}
export class JobListRequestDto extends createZodDto(JobListRequestSchema) {}
