import { Controller, Get, Query } from '@nestjs/common';
import { ApiOkResponse, ApiOperation, ApiQuery } from '@nestjs/swagger';
import { FilesystemListingRequestDto, FilesystemListingResponseDto } from '../dto/filesystem.dto.js';
import { FilesystemService } from '../services/filesystem.service.js';

@Controller('/yucca/fs')
export class FilesystemController {
  constructor(private readonly service: FilesystemService) {}

  @Get()
  @ApiQuery({ name: 'path', type: String, required: false })
  @ApiOkResponse({ type: FilesystemListingResponseDto })
  @ApiOperation({
    summary: 'List files',
    description: 'List the files and folders at a path on this server.',
  })
  async getFileListing(@Query() dto: FilesystemListingRequestDto): Promise<FilesystemListingResponseDto> {
    return this.service.getFileListing(dto);
  }
}
