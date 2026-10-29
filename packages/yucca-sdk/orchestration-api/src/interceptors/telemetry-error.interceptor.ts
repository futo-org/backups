import { CallHandler, ExecutionContext, HttpException, Injectable, NestInterceptor, Type } from '@nestjs/common';
import { Request } from 'express';
import { Observable, catchError, throwError } from 'rxjs';
import { controllers } from '../orchestrationApi.module.js';
import { TelemetryService } from '../services/telemetry.service.js';

@Injectable()
export class TelemetryErrorInterceptor implements NestInterceptor {
  constructor(private readonly telemetry: TelemetryService) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const futoBackupsControllers: Type[] = controllers;
    const isFutoBackupsRoute = futoBackupsControllers.includes(context.getClass());

    if (!isFutoBackupsRoute) {
      return next.handle();
    }

    return next.handle().pipe(
      catchError((error: unknown) => {
        const status = error instanceof HttpException ? error.getStatus() : 500;

        if (status >= 500) {
          const request = context.switchToHttp().getRequest<Request | undefined>();

          this.telemetry.submitStructuredLog('Unhandled request error', {
            method: request?.method,
            path: request?.url,
            error: error instanceof Error ? error : new Error(String(error)),
          });
        }

        return throwError(() => error);
      }),
    );
  }
}
