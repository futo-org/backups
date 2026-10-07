import { Controller, Get, NotFoundException, Param, Res, Sse } from '@nestjs/common';
import { ApiOkResponse, ApiOperation, ApiParam } from '@nestjs/swagger';
import { type Response } from 'express';
import { Observable } from 'rxjs';
import { RunResponseDto } from '../dto/repository.dto.js';
import { RunHistoryRepository } from '../repositories/runHistory.repository.js';
import { StorageRepository } from '../repositories/storage.repository.js';

@Controller('/yucca/logs')
export class RunHistoryController {
  constructor(
    private readonly repository: RunHistoryRepository,
    private readonly storage: StorageRepository,
  ) {}

  @Get('/:id')
  @ApiParam({ name: 'id', type: String })
  @ApiOkResponse({ type: RunResponseDto })
  @ApiOperation({
    summary: 'Get a run',
    description: 'Retrieve a run and its status.',
  })
  async getRun(@Param('id') id: string): Promise<RunResponseDto> {
    const run = await this.repository.get(id);
    if (!run) {
      throw new NotFoundException('Run not found');
    }

    return { run };
  }

  @Get('/:id/download')
  @ApiParam({ name: 'id', type: String })
  @ApiOkResponse({ content: { 'application/jsonl': { schema: { type: 'string', format: 'binary' } } } })
  @ApiOperation({
    summary: 'Download a run log',
    description: 'Download the log of a run.',
  })
  async downloadRunLog(@Param('id') id: string, @Res() response: Response): Promise<void> {
    const run = await this.repository.get(id);
    if (!run) {
      throw new NotFoundException('Run not found');
    }

    try {
      await this.storage.stat(run.logFilePath);
    } catch {
      throw new NotFoundException('Log file not found');
    }

    response.download(run.logFilePath, `${id}.jsonl`, {
      dotfiles: 'allow',
      headers: { 'Content-Type': 'application/jsonl' },
    });
  }

  @Sse('/:id/stream')
  @ApiParam({ name: 'id', type: String })
  @ApiOperation({
    summary: 'Stream a run log',
    description: 'Stream the log of a run.',
  })
  @ApiOkResponse({
    content: { 'text/event-stream': { schema: { type: 'string' } } },
    description: 'A stream of run log events.',
  })
  logStreamSse(@Param('id') id: string): Observable<MessageEvent> {
    return this.repository.getObservable(id);
  }
}
