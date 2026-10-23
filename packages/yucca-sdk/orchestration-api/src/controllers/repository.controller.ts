import { Body, Controller, Delete, Get, Param, Patch, Post, Put, Query } from '@nestjs/common';
import { ApiCreatedResponse, ApiOkResponse, ApiOperation, ApiParam, ApiQuery } from '@nestjs/swagger';
import { FilesystemListingRequestDto, FilesystemListingResponseDto } from '../dto/filesystem.dto.js';
import {
  JobResponseDto,
  ListSnapshotsResponseDto,
  RepositoryCheckImportResponseDto,
  RepositoryCreateRequestDto,
  RepositoryCreateResponseDto,
  RepositoryInspectResponseDto,
  RepositoryListResponseDto,
  RepositoryPrimaryBackendReconfigureRequestDto,
  RepositorySnapshotRestoreFromPointRequestDto,
  RepositorySnapshotRestoreRequestDto,
  RepositoryUpdateRequestDto,
  RepositoryUpdateResponseDto,
  RunHistoryResponseDto,
} from '../dto/repository.dto.js';
import { RepositoryService } from '../services/repository.service.js';

@Controller('/yucca/repository')
export class RepositoryController {
  constructor(private readonly service: RepositoryService) {}

  @Post()
  @ApiQuery({ name: 'backend', type: String, required: false })
  @ApiCreatedResponse({ type: RepositoryCreateResponseDto })
  @ApiOperation({
    summary: 'Create a new backup',
    description: 'Create a backup repository on a backend.',
  })
  createRepository(
    @Body() dto: RepositoryCreateRequestDto,
    @Query('backend') backendId?: string,
  ): Promise<RepositoryCreateResponseDto> {
    return this.service.createRepository(dto, backendId);
  }

  @Get()
  @ApiOkResponse({ type: RepositoryListResponseDto })
  @ApiOperation({
    summary: 'List backups',
    description: 'List the backup repositories known to this server.',
  })
  getRepositories(): Promise<RepositoryListResponseDto> {
    return this.service.getRepositories();
  }

  @Get('/inspect')
  @ApiQuery({ name: 'backend', type: String, required: false })
  @ApiOkResponse({ type: RepositoryInspectResponseDto })
  @ApiOperation({
    summary: 'List remote backups',
    description: 'List repositories on a backend that are not configured on this server.',
  })
  inspectRepositories(@Query('backend') backendId?: string): Promise<RepositoryInspectResponseDto> {
    return this.service.inspectRepositories(backendId);
  }

  @Patch('/:id')
  @ApiQuery({ name: 'backend', type: String, required: false })
  @ApiOkResponse({ type: RepositoryUpdateResponseDto })
  @ApiOperation({
    summary: 'Update a backup',
    description: 'Update the settings of a repository.',
  })
  updateRepository(
    @Param('id') id: string,
    @Body() dto: RepositoryUpdateRequestDto,
    @Query('backend') backendId?: string,
  ): Promise<RepositoryUpdateResponseDto> {
    return this.service.updateRepository(id, dto, backendId);
  }

  @Delete('/:id')
  @ApiOperation({
    summary: 'Remove a backup',
    description: 'Remove a repository from this server.',
  })
  @ApiOkResponse()
  deleteRepository(@Param('id') id: string): Promise<void> {
    return this.service.deleteRepository(id);
  }

  @Post('/:id')
  @ApiParam({ name: 'id', type: String })
  @ApiCreatedResponse({ type: JobResponseDto })
  @ApiOperation({
    summary: 'Start a backup',
    description: 'Queue a backup to a repository and return the ID of its job.',
  })
  createBackup(@Param('id') id: string): Promise<JobResponseDto> {
    return this.service.createBackup(id);
  }

  @Get('/:id/import')
  @ApiQuery({ name: 'backend', type: String })
  @ApiOkResponse({ type: RepositoryCheckImportResponseDto })
  @ApiOperation({
    summary: 'Check a repository import',
    description: 'Check that an existing repository on a backend can be opened with the recovery key.',
  })
  checkImportRepository(@Param('id') id: string, @Query('backend') backend: string) {
    return this.service.checkImportRepository(id, backend);
  }

  @Post('/:id/import')
  @ApiQuery({ name: 'backend', type: String })
  @ApiCreatedResponse({ type: RepositoryCreateResponseDto })
  @ApiOperation({
    summary: 'Import a repository',
    description: 'Add an existing repository on a backend to this server.',
  })
  importRepository(@Param('id') id: string, @Query('backend') backend: string): Promise<RepositoryCreateResponseDto> {
    return this.service.importRepository(id, backend);
  }

  @Put('/:id/backend')
  @ApiOkResponse({ type: RepositoryCreateResponseDto })
  @ApiOperation({
    summary: 'Change the primary backend',
    description:
      'Create a new empty repository on the selected backend and redirect future backups to it. Existing snapshots are not migrated.',
  })
  reconfigureRepositoryPrimaryBackend(
    @Param('id') id: string,
    @Body() dto: RepositoryPrimaryBackendReconfigureRequestDto,
  ): Promise<RepositoryCreateResponseDto> {
    return this.service.reconfigureRepositoryPrimaryBackend(id, dto);
  }

  @Get('/:id/runs')
  @ApiParam({ name: 'id', type: String })
  @ApiOkResponse({ type: RunHistoryResponseDto })
  @ApiOperation({
    summary: 'List backup runs',
    description: 'List the backup, prune and restore runs of a repository.',
  })
  getRunHistory(@Param('id') id: string): Promise<RunHistoryResponseDto> {
    return this.service.getRunHistory(id);
  }

  @Get('/:id/snapshots')
  @ApiParam({ name: 'id', type: String })
  @ApiOkResponse({ type: ListSnapshotsResponseDto })
  @ApiOperation({
    summary: 'List snapshots',
    description: 'List the snapshots in a repository.',
  })
  getSnapshots(@Param('id') id: string): Promise<ListSnapshotsResponseDto> {
    return this.service.getSnapshots(id);
  }

  @Post('/:id/snapshots/prune')
  @ApiParam({ name: 'id', type: String })
  @ApiCreatedResponse({ type: JobResponseDto })
  @ApiOperation({
    summary: 'Prune a repository',
    description: 'Queue the removal of snapshots outside the retention policy and return the ID of its job.',
  })
  pruneRepository(@Param('id') id: string): Promise<JobResponseDto> {
    return this.service.pruneRepository(id);
  }

  @Post('/:id/snapshots/:snapshot')
  @ApiParam({ name: 'id', type: String })
  @ApiParam({ name: 'snapshot', type: String })
  @ApiCreatedResponse({ type: JobResponseDto })
  @ApiOperation({
    summary: 'Restore a snapshot',
    description: 'Queue a restore of files from a snapshot and return the ID of its job.',
  })
  async restoreSnapshot(
    @Param('id') id: string,
    @Param('snapshot') snapshotId: string,
    @Body() dto: RepositorySnapshotRestoreRequestDto,
  ): Promise<JobResponseDto> {
    return this.service.restoreSnapshot(id, snapshotId, dto);
  }

  @Post('/:id/snapshots/:snapshot/restore-from-point')
  @ApiParam({ name: 'id', type: String })
  @ApiParam({ name: 'snapshot', type: String })
  @ApiQuery({ name: 'backend', type: String })
  @ApiCreatedResponse({ type: JobResponseDto })
  @ApiOperation({
    summary: 'Restore from snapshot',
    description: 'Restore the orchestrator to a previous state, wiping the current state.',
  })
  async restoreFromPoint(
    @Param('id') id: string,
    @Param('snapshot') snapshotId: string,
    @Query('backend') backendId: string,
    @Body() dto: RepositorySnapshotRestoreFromPointRequestDto,
  ): Promise<JobResponseDto> {
    return this.service.restoreFromPoint(id, snapshotId, backendId, dto);
  }

  @Delete('/:id/snapshots/:snapshot')
  @ApiParam({ name: 'id', type: String })
  @ApiParam({ name: 'snapshot', type: String })
  @ApiOkResponse({ type: ListSnapshotsResponseDto })
  @ApiOperation({
    summary: 'Delete a snapshot',
    description: 'Remove a snapshot from a repository.',
  })
  forgetSnapshot(@Param('id') id: string, @Param('snapshot') snapshot: string): Promise<void> {
    return this.service.forgetSnapshot(id, snapshot);
  }

  @Get('/:id/snapshots/:snapshot/listing')
  @ApiParam({ name: 'id', type: String })
  @ApiParam({ name: 'snapshot', type: String })
  @ApiQuery({ name: 'path', type: String, required: false })
  @ApiOkResponse({ type: FilesystemListingResponseDto })
  @ApiOperation({
    summary: 'List snapshot files',
    description: 'List the files and folders at a path in a snapshot.',
  })
  async getSnapshotListing(
    @Param('id') id: string,
    @Param('snapshot') snapshotId: string,
    @Query() dto: FilesystemListingRequestDto,
  ): Promise<FilesystemListingResponseDto> {
    return this.service.getSnapshotListing(id, snapshotId, dto);
  }
}
