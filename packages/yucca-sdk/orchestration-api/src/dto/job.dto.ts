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
    scanning: z.boolean(),
    estimatedEndAt: z.string().optional(),
    bytesDone: z.number().optional(),
    totalBytes: z.number().optional(),
    currentFiles: z.array(z.string()),
  })
  .meta({ id: 'JobProgressDto' });

const JobOutcomeSchema = z
  .object({
    errors: z.array(z.string()),
    summary: JobSummarySchema.optional(),
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
