import '@common/server/otel';

import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module.js';
import { env } from './env.js';
import { useSwagger } from './utils/openapi.js';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.setGlobalPrefix('/api');
  useSwagger(app, { write: env.NODE_ENV === 'development' });
  await app.listen(env.YUCCA_ADMIN_API_PORT);
}

void bootstrap();
