import { isoDatetimeToDate } from '@common/server';
import { createZodDto } from 'nestjs-zod';
import { z } from 'zod';

const InviteCodeSchema = z
  .object({
    id: z.string(),
    name: z.string(),
    code: z.string(),
    inviteUrl: z.string(),
    maxUses: z.number().nullable(),
    uses: z.number(),
    expiresAt: isoDatetimeToDate.nullable(),
    revokedAt: isoDatetimeToDate.nullable(),
    createdAt: isoDatetimeToDate,
  })
  .meta({ id: 'InviteCodeDto' });

const InviteCodeRedemptionSchema = z
  .object({
    userId: z.string(),
    email: z.string(),
    createdAt: isoDatetimeToDate,
  })
  .meta({ id: 'InviteCodeRedemptionDto' });

const InviteCodeListResponseSchema = z
  .object({ items: z.array(InviteCodeSchema) })
  .meta({ id: 'InviteCodeListResponseDto' });

const InviteCodeCreateRequestSchema = z
  .object({
    name: z.string().trim().min(1).max(100),
    code: z
      .string()
      .trim()
      .toUpperCase()
      .regex(/^[A-Z0-9-]{6,32}$/)
      .optional()
      .describe('Custom code (6–32 letters, digits or dashes); generated when omitted'),
    maxUses: z.int().min(1).optional().describe('Unlimited when omitted'),
    expiresAt: isoDatetimeToDate.optional().describe('Never expires when omitted'),
  })
  .meta({ id: 'InviteCodeCreateRequestDto' });

const InviteCodeResponseSchema = z.object({ inviteCode: InviteCodeSchema }).meta({ id: 'InviteCodeResponseDto' });

const InviteCodeGetResponseSchema = z
  .object({
    inviteCode: InviteCodeSchema,
    redemptions: z.array(InviteCodeRedemptionSchema),
  })
  .meta({ id: 'InviteCodeGetResponseDto' });

export class InviteCodeDto extends createZodDto(InviteCodeSchema) {}
export class InviteCodeListResponseDto extends createZodDto(InviteCodeListResponseSchema) {}
export class InviteCodeCreateRequestDto extends createZodDto(InviteCodeCreateRequestSchema) {}
export class InviteCodeResponseDto extends createZodDto(InviteCodeResponseSchema) {}
export class InviteCodeGetResponseDto extends createZodDto(InviteCodeGetResponseSchema) {}
