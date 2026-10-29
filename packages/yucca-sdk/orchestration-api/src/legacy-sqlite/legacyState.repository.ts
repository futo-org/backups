import { Injectable } from '@nestjs/common';
import { Kysely } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { rename } from 'node:fs/promises';
import { resolve } from 'node:path';
import { z } from 'zod';
import { ConfigurationKey, TelemetryLevel } from '../enum.js';
import { LoggingRepository } from '../repositories/logging.repository.js';
import { DB } from '../schema/index.js';
import { ConfigurationValues } from '../schema/tables/config.table.js';
import { ImmichRepositoryConfig } from '../schema/tables/repositoryIntegrationImmich.table.js';
import { openLegacyStateDatabase } from './legacySqlite.js';

const importedConfigValues: { [Key in ConfigurationKey]?: (value: string) => ConfigurationValues[Key] } = {
  [ConfigurationKey.EncryptionKey]: (value) => ({ key: value }),
  [ConfigurationKey.OnboardedKey]: () => ({ isOnboarded: true }),
  [ConfigurationKey.Telemetry]: (value) => ({ level: value as TelemetryLevel }),
  [ConfigurationKey.SkippedOnboardingExtraConfig]: () => ({ isSkipped: true }),
  [ConfigurationKey.IgnoredImmichDatabaseDumpWarning]: () => ({ isIgnored: true }),
  [ConfigurationKey.ResticOptionRestConnections]: (value) => ({ connections: Number.parseInt(value) }),
  [ConfigurationKey.SupportMode]: (value) => JSON.parse(value),
};

@Injectable()
export class LegacyStateRepository {
  constructor(
    @InjectKysely('orchestrator') private db: Kysely<DB>,
    private readonly logger: LoggingRepository,
  ) {
    this.logger.setContext(LegacyStateRepository.name);
  }

  async importFrom(statePath: string): Promise<void> {
    const path = resolve(statePath, 'state.sqlite3');
    if (!existsSync(path)) {
      return;
    }

    const legacy = await openLegacyStateDatabase(path);

    try {
      const config = await legacy.selectFrom('config').selectAll().execute();
      const backends = await legacy.selectFrom('backends').selectAll().execute();
      const repositories = await legacy.selectFrom('repositories').selectAll().execute();
      const paths = await legacy.selectFrom('repositoryPaths').selectAll().execute();
      const schedules = await legacy.selectFrom('schedules').selectAll().execute();
      const links = await legacy.selectFrom('repositorySchedules').selectAll().execute();
      const integrations = await legacy.selectFrom('repositoryIntegrationImmich').selectAll().execute();

      const backendIds = new Set(backends.map(({ id }) => id));
      const importedRepositories = repositories.filter(({ backendId }) => backendIds.has(backendId));
      const repositoryIds = new Map(
        importedRepositories.map(({ id }) => [id, z.uuid().safeParse(id).success ? id : randomUUID()]),
      );
      const scheduleIds = new Set(schedules.map(({ id }) => id));

      const importedConfig = config.flatMap(({ key, value }) => {
        const toValue = importedConfigValues[key as ConfigurationKey];
        return toValue ? [{ key: key as ConfigurationKey, value: toValue(value) }] : [];
      });
      const bytesPerSec = config.find(({ key }) => key === 'throttle-bytes-per-sec')?.value;
      if (bytesPerSec !== undefined) {
        const quietHours = config.find(({ key }) => key === 'throttle-quiet-hours')?.value;
        importedConfig.push({
          key: ConfigurationKey.Throttle,
          value: { bytesPerSec: Number.parseInt(bytesPerSec), quietHours: quietHours || undefined },
        });
      }

      const importedPaths = paths.filter(({ id }) => repositoryIds.has(id));
      const importedLinks = links.filter(
        ({ repository, schedule }) => repositoryIds.has(repository) && scheduleIds.has(schedule),
      );
      const importedIntegrations = integrations.filter(
        ({ id, scheduleId }) => repositoryIds.has(id) && scheduleIds.has(scheduleId),
      );

      await this.db.transaction().execute(async (tx) => {
        if (importedConfig.length > 0) {
          await tx.insertInto('futo_backups_config').values(importedConfig).execute();
        }

        if (backends.length > 0) {
          await tx
            .insertInto('futo_backups_backends')
            .values(backends.map(({ id, configuration }) => ({ id, configuration: JSON.parse(configuration) })))
            .execute();
        }

        if (importedRepositories.length > 0) {
          await tx
            .insertInto('futo_backups_repositories')
            .values(
              importedRepositories.map(({ id, retentionPolicy, ...repository }) => ({
                ...repository,
                id: repositoryIds.get(id),
                retentionPolicy: retentionPolicy === null ? null : JSON.parse(retentionPolicy),
              })),
            )
            .execute();
        }

        if (schedules.length > 0) {
          await tx
            .insertInto('futo_backups_schedule')
            .values(
              schedules.map(({ id, name, cron, paused, ordering }) => ({
                id,
                name,
                cron,
                paused: paused === 1,
                ordering: (JSON.parse(ordering) as string[]).flatMap(
                  (repositoryId) => repositoryIds.get(repositoryId) ?? [],
                ),
              })),
            )
            .execute();
        }

        if (importedPaths.length > 0) {
          await tx
            .insertInto('futo_backups_repository_path')
            .values(importedPaths.map(({ id, path }) => ({ repositoryId: repositoryIds.get(id)!, path })))
            .execute();
        }

        if (importedLinks.length > 0) {
          await tx
            .insertInto('futo_backups_repository_schedule')
            .values(
              importedLinks.map(({ repository, schedule }) => ({
                repositoryId: repositoryIds.get(repository)!,
                scheduleId: schedule,
              })),
            )
            .execute();
        }

        if (importedIntegrations.length > 0) {
          await tx
            .insertInto('futo_backups_integrations_immich_config')
            .values(
              importedIntegrations.map(({ id, scheduleId, configuration }) => {
                const { libraries, ...immich } = JSON.parse(configuration) as Omit<
                  ImmichRepositoryConfig,
                  'libraries'
                > & { libraries: 'all' | string[] };

                return {
                  repositoryId: repositoryIds.get(id)!,
                  scheduleId,
                  configuration: { ...immich, libraries: libraries === 'all' ? ['all'] : libraries },
                };
              }),
            )
            .execute();
        }
      });
    } finally {
      await legacy.destroy();
    }

    await rename(path, `${path}.imported`);
    this.logger.log(`Imported the legacy state database from ${path}`);
  }
}
