import { createZodDto } from 'nestjs-zod';
import { z } from 'zod';
import { ConnectionsSource } from '../enum.js';

export const MIN_CONNECTIONS = 1;
export const MAX_CONNECTIONS = 128;

const QuietHoursSchema = z
  .string()
  .regex(/^([01]\d|2[0-3]):[0-5]\d-([01]\d|2[0-3]):[0-5]\d$/, 'Invalid quiet hours, expected HH:MM-HH:MM');

const BandwidthSchema = z
  .object({
    bytesPerSec: z.number().int().min(0),
    quietHours: QuietHoursSchema.optional(),
  })
  .meta({ id: 'BandwidthDto' });

const ConnectionsOverrideSchema = z.number().int().min(MIN_CONNECTIONS).max(MAX_CONNECTIONS).nullable();

const ConnectionsSchema = z
  .object({
    override: ConnectionsOverrideSchema.meta({ description: 'Stored override, null when automatic' }),
    automatic: z.number().int().min(1).meta({ description: 'Connections used when no override is set' }),
    effective: z.number().int().min(1).meta({ description: 'Connections the next restic run will use' }),
    source: z.enum(ConnectionsSource).meta({ id: 'ConnectionsSource' }),
    min: z.number().int(),
    max: z.number().int(),
  })
  .meta({ id: 'ConnectionsDto' });

const ConfigUpdateRequestSchema = z
  .object({
    bandwidth: BandwidthSchema.optional(),
    connections: ConnectionsOverrideSchema.optional().meta({
      description: 'Restic REST connections override, null to resolve it automatically',
    }),
  })
  .meta({ id: 'ConfigUpdateRequestDto' });

const ConfigResponseSchema = z
  .object({ bandwidth: BandwidthSchema, connections: ConnectionsSchema })
  .meta({ id: 'ConfigResponseDto' });

export class BandwidthDto extends createZodDto(BandwidthSchema) {}
export class ConnectionsDto extends createZodDto(ConnectionsSchema) {}
export class ConfigUpdateRequestDto extends createZodDto(ConfigUpdateRequestSchema) {}
export class ConfigResponseDto extends createZodDto(ConfigResponseSchema) {}
