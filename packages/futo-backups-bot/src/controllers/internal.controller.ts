import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  NotFoundException,
  Param,
  Post,
  UseGuards,
} from '@nestjs/common';
import { InternalGuard } from 'src/middleware/internal.guard.js';
import { InviteService } from 'src/services/invite.service.js';
import { SupportService } from 'src/services/support.service.js';
import { TicketContext } from 'src/utils/ticketContext.js';
import { z } from 'zod';

const closeDropSchema = z.object({
  batchId: z.string().min(1),
  channelId: z.string().min(1),
  messageId: z.string().min(1),
});

const staffNoteSchema = z.object({
  staffThreadId: z.string().min(1),
  content: z.string().min(1).max(8192),
});

const threadIdSchema = z.string().regex(/^\d{17,20}$/u);

@Controller('/internal')
@UseGuards(InternalGuard)
export class InternalController {
  constructor(
    private readonly invite: InviteService,
    private readonly support: SupportService,
  ) {}

  @Get('/tickets/:threadId/context')
  async getTicketContext(@Param('threadId') threadId: string): Promise<TicketContext> {
    const parsed = threadIdSchema.safeParse(threadId);
    if (!parsed.success) {
      throw new NotFoundException('Ticket not found');
    }
    return this.support.getTicketContext(parsed.data);
  }

  @Post('/drops/close')
  @HttpCode(HttpStatus.NO_CONTENT)
  async closeDrop(@Body() body: unknown): Promise<void> {
    const parsed = closeDropSchema.safeParse(body);
    if (!parsed.success) {
      throw new BadRequestException(parsed.error.message);
    }
    await this.invite.closeDrop(parsed.data.batchId, parsed.data.channelId, parsed.data.messageId);
  }

  @Post('/staff-notes')
  @HttpCode(HttpStatus.NO_CONTENT)
  async postStaffNote(@Body() body: unknown): Promise<void> {
    const parsed = staffNoteSchema.safeParse(body);
    if (!parsed.success) {
      throw new BadRequestException(parsed.error.message);
    }
    await this.support.postStaffNote(parsed.data.staffThreadId, parsed.data.content);
  }
}
