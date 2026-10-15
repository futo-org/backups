import { applyDecorators, Injectable, SetMetadata } from '@nestjs/common';
import { JobName, MetadataKey } from './enum.js';

export type JobConfig = {
  name: JobName;
};

export const Job = (config: JobConfig) => applyDecorators(Injectable(), SetMetadata(MetadataKey.JobConfig, config));
