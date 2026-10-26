import { Controller, Delete, Get, HttpCode, NotFoundException, Param, Query, Res } from '@nestjs/common';
import { ApiNoContentResponse, ApiOkResponse, ApiOperation, ApiParam } from '@nestjs/swagger';
import { type Response } from 'express';
import { JobDto, JobListRequestDto, JobListResponseDto } from '../dto/job.dto.js';
import { JobRepository } from '../repositories/job.repository.js';
import { StorageRepository } from '../repositories/storage.repository.js';

@Controller('/yucca/jobs')
export class JobController {
  constructor(
    private readonly repository: JobRepository,
    private readonly storage: StorageRepository,
  ) {}

  @Get()
  @ApiOkResponse({ type: JobListResponseDto })
  @ApiOperation({
    summary: 'List jobs',
    description: 'List the jobs for a repository, newest first.',
  })
  async getJobs(@Query() { repositoryId }: JobListRequestDto): Promise<JobListResponseDto> {
    return { jobs: await this.repository.getAll(repositoryId) };
  }

  @Get('/:id')
  @ApiParam({ name: 'id', type: String })
  @ApiOkResponse({ type: JobDto })
  @ApiOperation({
    summary: 'Get a job',
    description: 'Get the status of a job.',
  })
  async getJob(@Param('id') id: string): Promise<JobDto> {
    const job = await this.repository.get(id);
    if (!job) {
      throw new NotFoundException('Job not found');
    }

    return job;
  }

  @Delete('/:id')
  @HttpCode(204)
  @ApiParam({ name: 'id', type: String })
  @ApiNoContentResponse()
  @ApiOperation({
    summary: 'Cancel a job',
    description: 'Cancel a queued job, or stop it if it is already running.',
  })
  cancelJob(@Param('id') id: string): Promise<void> {
    return this.repository.cancel(id);
  }

  @Get('/:id/download')
  @ApiParam({ name: 'id', type: String })
  @ApiOkResponse({ content: { 'application/jsonl': { schema: { type: 'string', format: 'binary' } } } })
  @ApiOperation({
    summary: 'Download a job log',
    description: 'Download the full log of a job as JSON lines.',
  })
  async downloadJobLog(@Param('id') id: string, @Res() response: Response): Promise<void> {
    const logFilePath = await this.repository.getLogFilePath(id);
    if (!logFilePath) {
      throw new NotFoundException('Job not found');
    }

    try {
      await this.storage.stat(logFilePath);
    } catch {
      throw new NotFoundException('Log file not found');
    }

    response.download(logFilePath, `${id}.jsonl`, {
      dotfiles: 'allow',
      headers: { 'Content-Type': 'application/jsonl' },
    });
  }
}
