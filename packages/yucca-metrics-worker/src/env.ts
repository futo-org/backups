import { z } from 'zod';

const schema = z.object({
  NODE_ENV: z.enum(['development', 'production', 'test', 'provision']).default('development'),

  YUCCA_METRICS_WORKER_PORT: z.coerce.number().min(1000),

  POSTGRES_HOST: z.string(),
  POSTGRES_PORT: z.coerce.number().default(5432),
  POSTGRES_USERNAME: z.string(),
  POSTGRES_PASSWORD: z.string(),
  POSTGRES_DATABASE: z.string(),
  POSTGRES_SSL: z.union([z.enum(['require', 'allow', 'prefer', 'verify-full']), z.boolean()]).default(false),

  TOPOLOGY_FILE: z.string().default('./topology.dev.json'),
  LEGACY_SITE_CODE: z.string(),
  LEGACY_STORAGE_CLUSTER_CODE: z.string(),

  INTERNAL_SECRET: z.string().default(''),

  FUTOPAY_URL: z.string().default(''),
  FUTOPAY_ORG_SLUG: z.string().default(''),
  FUTOPAY_API_KEY: z.string().default(''),
  FUTOPAY_USAGE_PERIOD: z.enum(['hour', 'day', 'month']).default('day'),
  FUTOPAY_USAGE_LOOKBACK_PERIODS: z.coerce.number().int().min(1).optional(),

  RADOS_ACCESS_KEY_ID: z.string().optional(),
  RADOS_SECRET_ACCESS_KEY: z.string().optional(),

  // Only used by the integration test harness to reach RGW directly.
  RADOS_ENDPOINT: z
    .url()
    .transform((url) => new URL(url))
    .optional(),
});

export const env = schema.parse(process.env);
