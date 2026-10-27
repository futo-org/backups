import { createZodDto } from 'nestjs-zod';
import { z } from 'zod';

export const MAX_SUPPORT_MODE_RUNS = 20;

const SupportModeUpdateRequestSchema = z
  .object({
    remainingRuns: z
      .int()
      .min(0)
      .max(MAX_SUPPORT_MODE_RUNS)
      .describe('How many more backup, cleanup, restore and delete runs use verbose restic logging'),
    streamToFuto: z.boolean().describe('Stream those runs’ logs to FUTO; requires the support-log-streaming feature'),
    includePaths: z.boolean().describe('Send file paths as-is instead of redacted placeholders'),
  })
  .meta({ id: 'SupportModeUpdateRequestDto' });

const SupportModeResponseSchema = SupportModeUpdateRequestSchema.extend({
  streamingAvailable: z.boolean().describe('Whether this account may stream support logs to FUTO'),
}).meta({ id: 'SupportModeResponseDto' });

export class SupportModeUpdateRequestDto extends createZodDto(SupportModeUpdateRequestSchema) {}
export class SupportModeResponseDto extends createZodDto(SupportModeResponseSchema) {}
