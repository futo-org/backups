import { createZodDto } from 'nestjs-zod';
import { z } from 'zod';
import { JobName, JobStatus } from '../enum.js';

export const JobSchema = z
  .object({
    id: z.string(),
    name: z.enum(JobName).meta({ id: 'JobName' }),
    repositoryId: z.string(),
    status: z.enum(JobStatus).meta({ id: 'JobStatus' }),
    error: z.string().optional(),
    queuedAt: z.string(),
    start: z.string().optional(),
    end: z.string().optional(),
  })
  .meta({ id: 'JobDto' });

const JobListResponseSchema = z.object({ jobs: z.array(JobSchema) }).meta({ id: 'JobListResponseDto' });

const JobListRequestSchema = z.object({ repositoryId: z.string() }).meta({ id: 'JobListRequestDto' });

export class JobDto extends createZodDto(JobSchema) {}
export class JobListResponseDto extends createZodDto(JobListResponseSchema) {}
export class JobListRequestDto extends createZodDto(JobListRequestSchema) {}
