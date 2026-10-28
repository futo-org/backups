import { BadRequestException, Controller, Get, ParseIntPipe, Query, UseGuards } from '@nestjs/common';
import { ApiExcludeController } from '@nestjs/swagger';
import { InternalGuard } from 'src/middleware/internal.guard.js';
import { BillingRepository } from 'src/repositories/billing.repository.js';

/**
 * Operator view of the FUTO Pay billing integration, for the mock stack's
 * console and for debugging a deployment.
 *
 * - webhook-deliveries: every delivery accepted on POST /api/billing/futopay/webhook,
 *   newest first. Pay's side of the same log is GET {FUTOPAY_URL}/api/v1/cloud/{org}/notifications.
 * - repositories: a customer's repositories, looked up by Pay's external customer id
 *   (the user's sub) or email. Pay only ever sees one usage report per user, so the
 *   repository ids (the bucket names the metrics worker samples) exist only here.
 * - users: every account, newest first, with its billing status and whether it is
 *   signed in, so a console can offer an account before it has a Polar customer
 *   (which only exists once Billing → Subscribe has started a checkout).
 */
@Controller('/internal/billing')
@UseGuards(InternalGuard)
@ApiExcludeController()
export class BillingInternalController {
  constructor(private readonly billing: BillingRepository) {}

  @Get('/webhook-deliveries')
  async listWebhookDeliveries(@Query('limit', new ParseIntPipe({ optional: true })) limit?: number) {
    const deliveries = await this.billing.listDeliveries(Math.min(Math.max(limit ?? 100, 1), 500));
    return { deliveries };
  }

  @Get('/users')
  async listUsers(@Query('limit', new ParseIntPipe({ optional: true })) limit?: number) {
    const users = await this.billing.listUsers(Math.min(Math.max(limit ?? 100, 1), 500));
    return { users };
  }

  @Get('/repositories')
  async listRepositories(@Query('sub') sub?: string, @Query('email') email?: string) {
    if (!sub && !email) {
      throw new BadRequestException('sub or email is required');
    }
    const user = await this.billing.findUser({ sub: sub ?? null, email: email ?? null });
    if (!user) {
      return { user: null, repositories: [] };
    }
    const repositories = await this.billing.listRepositories(user.id);
    return { user, repositories };
  }
}
