import z from 'zod';

export const emailEnv = z
  .object({
    RESEND_API_URL: z.url().default('https://api.resend.com'),
    // optional, email skip sending if not present
    RESEND_API_KEY: z.string().optional(),
    EMAIL_FROM_ADDRESS: z.string().default('FUTO Backups <noreply@backups.futo.cloud>'),
  })
  .parse(process.env);
