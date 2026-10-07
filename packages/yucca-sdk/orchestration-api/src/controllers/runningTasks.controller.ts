import { Controller, Get, Param, Post } from '@nestjs/common';
import { ApiCreatedResponse, ApiOkResponse, ApiOperation, ApiParam } from '@nestjs/swagger';
import { RunningTaskListResponse } from '../dto/runningTasks.dto.js';
import { RunningTasksService } from '../services/runningTasks.service.js';

@Controller('/yucca/tasks')
export class RunningTasksController {
  constructor(private readonly service: RunningTasksService) {}

  @Get()
  @ApiOkResponse({ type: RunningTaskListResponse })
  @ApiOperation({
    summary: 'List running tasks',
    description: 'List the tasks running on this server.',
  })
  getRunningTasks(): RunningTaskListResponse {
    return this.service.getTasks();
  }

  @Post('/:parentId/cancel')
  @ApiParam({ name: 'parentId', type: String })
  @ApiOperation({
    summary: 'Cancel a task',
    description: 'Cancel a running task and its subtasks.',
  })
  @ApiCreatedResponse()
  cancelTask(@Param('parentId') parentId: string): void {
    this.service.cancelTask(parentId);
  }
}
