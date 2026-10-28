import { createZodDto } from 'nestjs-zod';
import { z } from 'zod';
import { JobName, JobStatus } from '../enum.js';

const JobSummarySchema = z
  .discriminatedUnion('type', [
    z.object({
      type: z.literal('backup'),
      filesNew: z.int(),
      filesChanged: z.int(),
      totalFilesProcessed: z.int(),
      totalBytesProcessed: z.int(),
      snapshotId: z.string().optional(),
    }),
    z.object({
      type: z.literal('restore'),
      filesRestored: z.int(),
      filesSkipped: z.int(),
      bytesRestored: z.int(),
    }),
    z.object({
      type: z.literal('prune'),
      kept: z.int(),
      removed: z.int(),
    }),
  ])
  .meta({ id: 'JobSummaryDto' });

const JobProgressSchema = z
  .object({
    percentDone: z.number().meta({ format: 'double' }),
    scanning: z.boolean(),
    estimatedEndAt: z.string().optional(),
    bytesDone: z.int().optional(),
    totalBytes: z.int().optional(),
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
        droppedLines: z.int().describe('Log lines that could not be streamed in time'),
        localDroppedLines: z.int().describe('Log lines that could not be written to the local support log'),
      })
      .optional()
      .meta({ id: 'JobSupportDto' }),
  })
  .meta({ id: 'JobOutcomeDto' });

export const JobSchema = z
  .object({
    id: z.string(),
    name: z.enum(JobName).meta({ id: 'YuccaJobName' }),
    repositoryId: z.string(),
    status: z.enum(JobStatus).meta({ id: 'YuccaJobStatus' }),
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
