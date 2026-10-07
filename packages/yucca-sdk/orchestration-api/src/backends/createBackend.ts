import { BackendType } from '../enum.js';
import { BackendConfiguration } from '../schema/tables/backend.table.js';
import { LocalBackend } from './local.backend.js';
import { S3Backend } from './s3.backend.js';
import { YuccaBackend } from './yucca.backend.js';

export function createBackend(configuration: BackendConfiguration) {
  switch (configuration.type) {
    case BackendType.Yucca: {
      return new YuccaBackend(configuration);
    }
    case BackendType.Local: {
      return new LocalBackend(configuration);
    }
    case BackendType.S3: {
      return new S3Backend(configuration);
    }
  }
}
