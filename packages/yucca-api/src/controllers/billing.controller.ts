import {
  Controller,
  Get,
  Headers,
  HttpCode,
  HttpStatus,
  ParseBoolPipe,
  Post,
  Query,
  type RawBodyRequest,
  Req,
} from '@nestjs/common';
import { ApiExcludeEndpoint, ApiOkResponse, ApiQuery } from '@nestjs/swagger';
import { type Request } from 'express';
import { ZodSerializerDto } from 'nestjs-zod';
import { AuthDto } from 'src/dto/auth.dto.js';
import {
  BillingStatementListResponseDto,
  BillingStatusDto,
  BillingWebhookReceiptDto,
  StartSubscriptionResponseDto,
  SubscriptionPortalResponseDto,
} from 'src/dto/billing.dto.js';
import { Auth, AuthRoute } from 'src/middleware/auth.guard.js';
import { BillingService } from 'src/services/billing.service.js';

@Controller('/billing')
export class BillingController {
  constructor(private readonly billing: BillingService) {}

  @Get()
  @AuthRoute()
  @ApiOkResponse({ type: BillingStatusDto })
  @ApiQuery({ name: 'refresh', required: false, type: Boolean })
  @ZodSerializerDto(BillingStatusDto)
  getBillingStatus(
    @Auth() auth: AuthDto,
    @Query('refresh', new ParseBoolPipe({ optional: true })) refresh?: boolean,
  ): Promise<BillingStatusDto> {
    return this.billing.getBillingStatus(auth, refresh);
  }

  @Get('/statements')
  @AuthRoute()
  @ApiOkResponse({ type: BillingStatementListResponseDto })
  @ZodSerializerDto(BillingStatementListResponseDto)
  listBillingStatements(@Auth() auth: AuthDto): Promise<BillingStatementListResponseDto> {
    return this.billing.listStatements(auth);
  }

  @Post('/subscribe')
  @AuthRoute()
  @HttpCode(HttpStatus.OK)
  @ApiOkResponse({ type: StartSubscriptionResponseDto })
  startSubscription(
    @Auth() auth: AuthDto,
    @Headers('origin') origin: string | undefined,
  ): Promise<StartSubscriptionResponseDto> {
    return this.billing.startSubscription(auth, origin);
  }

  @Post('/portal')
  @AuthRoute()
  @HttpCode(HttpStatus.OK)
  @ApiOkResponse({ type: SubscriptionPortalResponseDto })
  openSubscriptionPortal(
    @Auth() auth: AuthDto,
    @Headers('origin') origin: string | undefined,
  ): Promise<SubscriptionPortalResponseDto> {
    return this.billing.openSubscriptionPortal(auth, origin);
  }

  @Post('/futopay/webhook')
  @HttpCode(HttpStatus.OK)
  @ApiExcludeEndpoint()
  futopayWebhook(@Req() request: RawBodyRequest<Request>): Promise<BillingWebhookReceiptDto> {
    return this.billing.futopayWebhook(request.rawBody ?? null, request.headers as Record<string, string>);
  }
}
