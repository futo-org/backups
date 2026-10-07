import { BackupStatus } from 'src/enum.js';
import z from 'zod';

export const BackupStatusSchema = z.enum(BackupStatus).meta({ id: 'BackupStatus' });
