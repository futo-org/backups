import { Column, PrimaryColumn, Table } from '@immich/sql-tools';
import { ConfigurationKey, TelemetryLevel } from '../../enum.js';
import type { ResticProxyThrottle } from '../../proxy/resticProxy.js';
import type { SupportModeSettings } from '../../repositories/config.repository.js';
import { configuration_key_enum } from '../enums.js';

export type ConfigurationValues = {
  [ConfigurationKey.EncryptionKey]: { key: string };
  [ConfigurationKey.OnboardedKey]: { isOnboarded: boolean };
  [ConfigurationKey.Telemetry]: { level: TelemetryLevel };
  [ConfigurationKey.SkippedOnboardingExtraConfig]: { isSkipped: boolean };
  [ConfigurationKey.IgnoredImmichDatabaseDumpWarning]: { isIgnored: boolean };
  [ConfigurationKey.ResticOptionRestConnections]: { connections: number };
  [ConfigurationKey.SessionSecret]: { secret: string };
  [ConfigurationKey.StatePath]: { path: string };
  [ConfigurationKey.Throttle]: ResticProxyThrottle;
  [ConfigurationKey.SupportMode]: SupportModeSettings;
};

@Table({ name: 'futo_backups_config' })
export class ConfigTable<Key extends ConfigurationKey = ConfigurationKey> {
  @PrimaryColumn({ type: 'enum', enum: configuration_key_enum })
  key!: Key;

  @Column({ type: 'jsonb' })
  value!: ConfigurationValues[Key];
}
