import {
  BadGatewayException,
  BadRequestException,
  Body,
  Controller,
  HttpCode,
  HttpStatus,
  Post,
  UseGuards,
} from '@nestjs/common';
import { InternalGuard } from 'src/middleware/internal.guard.js';
import { UsageReportRepository } from 'src/repositories/usageReport.repository.js';
import { MetricsService } from 'src/services/metrics.service.js';
import { UsageReportService } from 'src/services/usageReport.service.js';
import { z } from 'zod';

const closePeriodSchema = z.object({
  periodStart: z.iso.datetime({ offset: true }).transform((value) => new Date(value)),
  periodEnd: z.iso.datetime({ offset: true }).transform((value) => new Date(value)),
  // Close the period for this user only (their OIDC sub). The scheduled run
  // closes calendar periods for everyone; a test driver closing an ad-hoc
  // period for one customer must not report that period for every other user
  // too, which overlaps their months and bills them repeatedly
  sub: z.string().min(1).optional(),
});

@Controller('/internal')
@UseGuards(InternalGuard)
export class InternalController {
  constructor(
    private readonly metrics: MetricsService,
    private readonly usage: UsageReportService,
    private readonly reports: UsageReportRepository,
  ) {}

  @Post('/metrics/sync')
  @HttpCode(HttpStatus.OK)
  async sync() {
    await this.metrics.sync();
    return { status: 'ok' };
  }

  @Post('/usage/close-period')
  @HttpCode(HttpStatus.OK)
  async closePeriod(@Body() body: unknown) {
    const parsed = closePeriodSchema.safeParse(body);
    if (!parsed.success) {
      throw new BadRequestException(parsed.error.issues.map((issue) => `${issue.path.join('.')}: ${issue.message}`));
    }
    const { sub, ...period } = parsed.data;
    const created = await this.usage.closePeriod(period, sub);
    let results;
    try {
      results = await this.usage.sendPending();
    } catch (error) {
      // The rows stay pending (sendPending marked them failed) and the next
      // run retries; tell the caller what FUTO Pay said rather than a bare 500
      throw new BadGatewayException(
        `${created} report(s) created but sending to FUTO Pay failed: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    const reports = await this.reports.listForPeriod(period.periodStart);
    return { created, results, reports };
  }
}
