import { Inject, Injectable } from '@nestjs/common';
import { Kysely } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { randomBytes } from 'node:crypto';
import { availableParallelism } from 'node:os';
import { resolve } from 'node:path';
import { ConfigurationKey, TelemetryLevel } from '../enum.js';
import { type ModuleConfig, ModuleConfigProvider } from '../moduleConfig.js';
import type { ResticProxyThrottle } from '../proxy/resticProxy.js';
import { DB } from '../schema/index.js';
import { ConfigurationValues } from '../schema/tables/config.table.js';
import { yuccaWellKnown } from '../wellKnown.js';
import { LoggingRepository } from './logging.repository.js';

export type ResticPlacement = { siteCode: string | null; storageClusterCode: string | null };

export type SupportModeSettings = { remainingRuns: number; streamToFuto: boolean; includePaths: boolean };

const SUPPORT_MODE_OFF: SupportModeSettings = { remainingRuns: 0, streamToFuto: false, includePaths: false };

const parseSupportMode = (value: Partial<SupportModeSettings> | undefined): SupportModeSettings =>
  value ? { ...SUPPORT_MODE_OFF, ...value } : SUPPORT_MODE_OFF;

@Injectable()
export class ConfigRepository {
  constructor(
    @InjectKysely('orchestrator') private db: Kysely<DB>,
    @Inject(ModuleConfigProvider) private moduleConfig: ModuleConfig,
    private readonly logger: LoggingRepository,
  ) {
    this.logger.setContext(ConfigRepository.name);
  }

  async bootstrap() {
    const statePath = resolve(this.moduleConfig.statePath);
    const hasKey = await this.hasEncryptionKey();

    if (!hasKey) {
      await this.assertStateIsEmpty(statePath);

      this.logger.warn(
        `Generating a new master encryption key for the state in ${statePath}. Backups written with a previous key cannot be decrypted with this one.`,
      );

      await this.set(ConfigurationKey.EncryptionKey, { key: randomBytes(32).toString('hex') });
    }

    await this.recordStatePath(statePath);

    const hasSecret = await this.hasSessionSecret();

    if (!hasSecret) {
      await this.set(ConfigurationKey.SessionSecret, { secret: randomBytes(32).toString('hex') });
    }
  }

  async getStateSummary() {
    const [{ backends }] = await this.db
      .selectFrom('futo_backups_backends')
      .select((eb) => eb.fn.countAll<number>().as('backends'))
      .execute();

    const [{ repositories }] = await this.db
      .selectFrom('futo_backups_repositories')
      .select((eb) => eb.fn.countAll<number>().as('repositories'))
      .execute();

    const [{ activeSchedules }] = await this.db
      .selectFrom('futo_backups_schedule')
      .where('paused', '=', false)
      .select((eb) => eb.fn.countAll<number>().as('activeSchedules'))
      .execute();

    return { backends, repositories, activeSchedules };
  }

  private async assertStateIsEmpty(statePath: string) {
    const { backends, repositories } = await this.getStateSummary();

    if (backends === 0 && repositories === 0) {
      return;
    }

    throw new Error(
      `The state in ${statePath} has ${backends} backend(s) and ${repositories} repository(ies) but no master encryption key. Refusing to generate one, as that would make those backups undecryptable. Restore the original state database.`,
    );
  }

  private async recordStatePath(statePath: string) {
    const recorded = await this.getOptional(ConfigurationKey.StatePath);
    const previous = recorded?.path;

    if (previous === statePath) {
      return;
    }

    if (previous) {
      this.logger.warn(
        `The state database was created in ${previous} but is being opened from ${statePath}. If the original directory is still populated, two installations are now diverging.`,
      );
    }

    await this.set(ConfigurationKey.StatePath, { path: statePath });
  }

  private async set<Key extends ConfigurationKey>(key: Key, value: ConfigurationValues[Key]) {
    await this.db
      .insertInto('futo_backups_config')
      .values({ key, value })
      .onConflict((oc) => oc.column('key').doUpdateSet({ value }))
      .execute();
  }

  private async get<Key extends ConfigurationKey>(key: Key) {
    const { value } = await this.db
      .selectFrom('futo_backups_config')
      .where('key', '=', key)
      .select('value')
      .executeTakeFirstOrThrow();

    return value as ConfigurationValues[Key];
  }

  private async getOptional<Key extends ConfigurationKey>(key: Key) {
    const row = await this.db
      .selectFrom('futo_backups_config')
      .where('key', '=', key)
      .select('value')
      .executeTakeFirst();

    return row?.value as ConfigurationValues[Key] | undefined;
  }

  private async has(key: ConfigurationKey) {
    const row = await this.db.selectFrom('futo_backups_config').where('key', '=', key).select('key').executeTakeFirst();

    return !!row;
  }

  async hasEncryptionKey() {
    return this.has(ConfigurationKey.EncryptionKey);
  }

  async getMasterEncryptionKey(): Promise<string> {
    const { key } = await this.get(ConfigurationKey.EncryptionKey);
    return key;
  }

  async deriveEncryptionKey(info: `repository-${string}`): Promise<Uint8Array> {
    const encryptionKey = await this.getMasterEncryptionKey();
    const masterKey = Buffer.from(encryptionKey, 'hex');

    const key = new Uint8Array(
      await crypto.subtle.deriveBits(
        {
          name: 'HKDF',
          hash: 'SHA-256',
          info: Buffer.from(info),
          salt: Buffer.from(Array.from({ length: 32 }).fill(0) as number[]),
        },
        await crypto.subtle.importKey('raw', masterKey, 'HKDF', false, ['deriveBits']),
        256,
      ),
    );

    return key;
  }

  async importEncryptionKey(key: string): Promise<void> {
    await this.set(ConfigurationKey.EncryptionKey, { key });
  }

  async hasOnboardedKey() {
    return this.has(ConfigurationKey.OnboardedKey);
  }

  async confirmKeyOnboarded() {
    return this.set(ConfigurationKey.OnboardedKey, { isOnboarded: true });
  }

  async hasTelemetry() {
    return this.has(ConfigurationKey.Telemetry);
  }

  async enableTelemetry() {
    return this.set(ConfigurationKey.Telemetry, { level: TelemetryLevel.Full });
  }

  async hasSkippedExtraConfig() {
    return this.has(ConfigurationKey.SkippedOnboardingExtraConfig);
  }

  async skipExtraConfig() {
    return this.set(ConfigurationKey.SkippedOnboardingExtraConfig, { isSkipped: true });
  }

  async hasIgnoredImmichDatabaseDumpWarning() {
    return this.has(ConfigurationKey.IgnoredImmichDatabaseDumpWarning);
  }

  async ignoreImmichDatabaseDumpWarning() {
    return this.set(ConfigurationKey.IgnoredImmichDatabaseDumpWarning, { isIgnored: true });
  }

  async hasSessionSecret() {
    return this.has(ConfigurationKey.SessionSecret);
  }

  async getSessionSecret(): Promise<Buffer> {
    const { secret } = await this.get(ConfigurationKey.SessionSecret);
    return Buffer.from(secret, 'hex');
  }

  getThrottle(): Promise<ResticProxyThrottle | undefined> {
    return this.getOptional(ConfigurationKey.Throttle);
  }

  async setThrottle(throttle: ResticProxyThrottle) {
    await this.set(ConfigurationKey.Throttle, throttle);
  }

  async getSupportMode(): Promise<SupportModeSettings> {
    return parseSupportMode(await this.getOptional(ConfigurationKey.SupportMode));
  }

  async setSupportMode(settings: SupportModeSettings) {
    await this.set(ConfigurationKey.SupportMode, settings);
  }

  async consumeSupportModeRun(): Promise<SupportModeSettings | undefined> {
    return this.db.transaction().execute(async (trx) => {
      const row = await trx
        .selectFrom('futo_backups_config')
        .where('key', '=', ConfigurationKey.SupportMode)
        .select('value')
        .forUpdate()
        .executeTakeFirst();

      const settings = parseSupportMode(row?.value as SupportModeSettings | undefined);
      if (settings.remainingRuns <= 0) {
        return;
      }

      await trx
        .updateTable('futo_backups_config')
        .set({ value: { ...settings, remainingRuns: settings.remainingRuns - 1 } })
        .where('key', '=', ConfigurationKey.SupportMode)
        .execute();

      return settings;
    });
  }

  async getResticOptions(
    placement: ResticPlacement,
  ): Promise<{ connections: number; packSizeMib: number | undefined }> {
    const siteCode = placement.siteCode ?? undefined;
    const clusterCode = placement.storageClusterCode ?? undefined;
    const cores = availableParallelism();

    const override = await this.getOptional(ConfigurationKey.ResticOptionRestConnections);
    let connections = override?.connections;
    if (!connections) {
      const wellKnownConnections = await yuccaWellKnown.getConnections(cores, siteCode, clusterCode);
      connections = wellKnownConnections ?? cores;
    }

    return { connections, packSizeMib: await yuccaWellKnown.getPackSizeMib(siteCode, clusterCode) };
  }
}
