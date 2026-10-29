import { Body, Controller, Delete, Get, Param, Patch, Post } from '@nestjs/common';
import { ApiCreatedResponse, ApiOkResponse, ApiOperation, ApiParam } from '@nestjs/swagger';
import {
  ScheduleCreateRequestDto,
  ScheduleCreateResponseDto,
  ScheduleListResponseDto,
  ScheduleUpdateRequestDto,
  ScheduleUpdateResponseDto,
} from '../dto/schedule.dto.js';
import { ScheduleService } from '../services/schedule.service.js';

@Controller('/futo-backups/schedule')
export class ScheduleController {
  constructor(private readonly service: ScheduleService) {}

  @Post()
  @ApiCreatedResponse({ type: ScheduleCreateResponseDto })
  @ApiOperation({
    summary: 'Create a schedule',
    description: 'Create a backup schedule for one or more repositories.',
  })
  createSchedule(@Body() dto: ScheduleCreateRequestDto): Promise<ScheduleCreateResponseDto> {
    return this.service.createSchedule(dto);
  }

  @Get()
  @ApiOkResponse({ type: ScheduleListResponseDto })
  @ApiOperation({
    summary: 'List schedules',
    description: 'List the backup schedules.',
  })
  getSchedules(): Promise<ScheduleListResponseDto> {
    return this.service.getSchedules();
  }

  @Patch('/:id')
  @ApiParam({ name: 'id', type: String })
  @ApiOkResponse({ type: ScheduleUpdateResponseDto })
  @ApiOperation({
    summary: 'Update a schedule',
    description: 'Update a backup schedule.',
  })
  updateSchedule(@Param('id') id: string, @Body() dto: ScheduleUpdateRequestDto): Promise<ScheduleUpdateResponseDto> {
    return this.service.updateSchedule(id, dto);
  }

  @Delete('/:id')
  @ApiParam({ name: 'id', type: String })
  @ApiOperation({
    summary: 'Delete a schedule',
    description: 'Delete a backup schedule.',
  })
  @ApiOkResponse()
  removeSchedule(@Param('id') id: string): Promise<void> {
    return this.service.removeSchedule(id);
  }
}
