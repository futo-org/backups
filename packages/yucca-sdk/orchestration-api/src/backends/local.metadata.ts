import { randomUUID } from 'node:crypto';
import { readFile, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { z } from 'zod';

export const LOCAL_METADATA_FILE_NAME = 'futo-backups.json';

const LocalMetadataSchema = z.object({
  name: z.string().optional().catch(undefined),
});

const LocalMetadataContentSchema = z.record(z.string(), z.unknown());

export type LocalMetadataFields = z.infer<typeof LocalMetadataSchema>;

export class LocalMetadata {
  private readonly path: string;

  constructor(directory: string) {
    this.path = join(directory, LOCAL_METADATA_FILE_NAME);
  }

  async read(): Promise<LocalMetadataFields> {
    return LocalMetadataSchema.parse(await this.readContent());
  }

  async update(changes: LocalMetadataFields): Promise<void> {
    await this.writeContent({ ...(await this.readContent()), ...changes });
  }

  private async readContent(): Promise<Record<string, unknown>> {
    try {
      return LocalMetadataContentSchema.parse(JSON.parse(await readFile(this.path, 'utf8')));
    } catch {
      return {};
    }
  }

  private async writeContent(content: Record<string, unknown>) {
    const temporaryPath = `${this.path}.${randomUUID()}.tmp`;
    try {
      await writeFile(temporaryPath, JSON.stringify(content), { flag: 'wx' });
      await rename(temporaryPath, this.path);
    } finally {
      await rm(temporaryPath, { force: true });
    }
  }
}
