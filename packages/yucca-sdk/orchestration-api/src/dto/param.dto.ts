import { createZodDto } from 'nestjs-zod';
import { z } from 'zod';

const UUIDParamSchema = z.object({ id: z.uuid() });

export class UUIDParamDto extends createZodDto(UUIDParamSchema) {}
