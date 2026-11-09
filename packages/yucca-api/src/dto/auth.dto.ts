import { createZodDto } from 'nestjs-zod';
import { DeviceFlowEventType, DeviceFlowFailureReason, DeviceFlowPollStatus } from 'src/enum.js';
import { z } from 'zod';

const AuthSchema = z
  .object({
    id: z.string(),
    name: z.string(),
    email: z.string(),
    sessionId: z.string(),
    connectionId: z.string().nullable(),
    features: z.record(z.string(), z.boolean()),
  })
  .meta({ id: 'AuthDto' });

const DeviceFlowFailureReasonSchema = z.enum(DeviceFlowFailureReason).meta({ id: 'DeviceFlowFailureReason' });

const DeviceFlowEventSchema = z
  .object({
    type: z.enum(DeviceFlowEventType).meta({ id: 'DeviceFlowEventType', deprecated: true }),
    userCode: z.string().optional(),
    verificationUri: z.string().optional(),
    accessToken: z.string().optional(),
    userId: z.string().optional(),
    reason: DeviceFlowFailureReasonSchema.optional(),
  })
  .meta({ id: 'DeviceFlowEventDto', deprecated: true });

const DeviceFlowStartSchema = z
  .object({
    deviceCode: z.string(),
    userCode: z.string(),
    verificationUri: z.string(),
    verificationUriComplete: z.string().optional(),
    expiresIn: z.number().int().describe('Seconds until the device code expires'),
    interval: z.number().int().optional().describe('Minimum seconds between polls'),
  })
  .meta({ id: 'DeviceFlowStartDto' });

const DeviceFlowIdentityPollRequestSchema = z
  .object({
    deviceCode: z.string().min(1),
  })
  .meta({ id: 'DeviceFlowIdentityPollRequestDto' });

const DeviceFlowPollRequestSchema = DeviceFlowIdentityPollRequestSchema.extend({
  connectionType: z.string().optional().describe('immich | standalone | restic'),
  connectionName: z.string().optional().describe('Instance name, e.g. a hostname'),
}).meta({ id: 'DeviceFlowPollRequestDto' });

const DeviceFlowPollSchema = z
  .object({
    status: z.enum(DeviceFlowPollStatus).meta({ id: 'DeviceFlowPollStatus' }),
    accessToken: z.string().optional(),
    userId: z.string().optional(),
    reason: DeviceFlowFailureReasonSchema.optional(),
  })
  .meta({ id: 'DeviceFlowPollDto' });

export class AuthDto extends createZodDto(AuthSchema) {}
export class DeviceFlowEventDto extends createZodDto(DeviceFlowEventSchema) {}
export class DeviceFlowStartDto extends createZodDto(DeviceFlowStartSchema) {}
export class DeviceFlowIdentityPollRequestDto extends createZodDto(DeviceFlowIdentityPollRequestSchema) {}
export class DeviceFlowPollRequestDto extends createZodDto(DeviceFlowPollRequestSchema) {}
export class DeviceFlowPollDto extends createZodDto(DeviceFlowPollSchema) {}
