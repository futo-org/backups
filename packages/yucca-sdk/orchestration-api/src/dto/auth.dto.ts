import { createZodDto } from 'nestjs-zod';
import { z } from 'zod';
import { DeviceFlowFailureReason, DeviceFlowPollStatus } from '../enum.js';

const DeviceFlowFailureReasonSchema = z.enum(DeviceFlowFailureReason).meta({ id: 'DeviceFlowFailureReason' });

const DeviceFlowStartSchema = z
  .object({
    deviceCode: z.string().describe('Device verification code'),
    userCode: z.string().describe('End-user verification code'),
    verificationUri: z.string().describe('End-user verification URI'),
    verificationUriComplete: z.string().optional().describe('Verification URI including the user code'),
    expiresIn: z.number().int().describe('Seconds until the device code expires'),
    interval: z.number().int().optional().describe('Minimum seconds between polls'),
  })
  .meta({ id: 'DeviceFlowStartDto' });

const DeviceFlowIdentityPollRequestSchema = z
  .object({
    deviceCode: z.string().min(1).describe('Device verification code'),
  })
  .meta({ id: 'DeviceFlowIdentityPollRequestDto' });

const DeviceFlowPollRequestSchema = DeviceFlowIdentityPollRequestSchema.extend({
  connectionType: z.string().optional().describe('immich | standalone | restic'),
  connectionName: z.string().optional().describe('Instance name, e.g. a hostname'),
}).meta({ id: 'DeviceFlowPollRequestDto' });

const DeviceFlowPollSchema = z
  .object({
    status: z.enum(DeviceFlowPollStatus).meta({ id: 'DeviceFlowPollStatus', description: 'Poll status' }),
    accessToken: z.string().optional().describe('Device session token'),
    backendId: z.string().optional().describe('Connected backend ID'),
    userId: z.string().optional().describe('Authenticated user ID'),
    reason: DeviceFlowFailureReasonSchema.optional().describe('Failure reason'),
  })
  .meta({ id: 'DeviceFlowPollDto' });

const CreateSessionRequestSchema = z.object({ token: z.string() }).meta({ id: 'CreateSessionRequestDto' });

export class DeviceFlowStartDto extends createZodDto(DeviceFlowStartSchema) {}
export class DeviceFlowIdentityPollRequestDto extends createZodDto(DeviceFlowIdentityPollRequestSchema) {}
export class DeviceFlowPollRequestDto extends createZodDto(DeviceFlowPollRequestSchema) {}
export class DeviceFlowPollDto extends createZodDto(DeviceFlowPollSchema) {}
export class CreateSessionRequestDto extends createZodDto(CreateSessionRequestSchema) {}
