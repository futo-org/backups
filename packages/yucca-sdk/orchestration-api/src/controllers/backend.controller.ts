import { Body, Controller, Get, Post } from '@nestjs/common';
import { ApiCreatedResponse, ApiOkResponse, ApiOperation } from '@nestjs/swagger';
import { BackendResponseDto, BackendsResponseDto, CreateLocalBackendRequestDto } from '../dto/backend.dto.js';
import { BackendService } from '../services/backend.service.js';

@Controller('/futo-backups/backend')
export class BackendController {
  constructor(private readonly service: BackendService) {}

  @Get()
  @ApiOkResponse({ type: BackendsResponseDto })
  @ApiOperation({
    summary: 'List backends',
    description: 'List the storage backends configured on this server.',
  })
  getBackends(): Promise<BackendsResponseDto> {
    return this.service.getBackends();
  }

  @Post('local')
  @ApiCreatedResponse({ type: BackendResponseDto })
  @ApiOperation({
    summary: 'Create a local backend',
    description: 'Add a storage backend that writes to a local path on this server.',
  })
  createLocalBackend(@Body() dto: CreateLocalBackendRequestDto): Promise<BackendResponseDto> {
    return this.service.createLocalBackend(dto);
  }
}
