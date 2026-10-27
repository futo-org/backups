import { Column, PrimaryColumn, Table } from '@immich/sql-tools';
import { ConfigurationKey, TelemetryLevel } from '../../enum.js';
import { configuration_key_enum } from '../enums.js';

export type ConfigurationValues = {
  [ConfigurationKey.EncryptionKey]: string;
  [ConfigurationKey.OnboardedKey]: boolean;
  [ConfigurationKey.Telemetry]: TelemetryLevel;
  [ConfigurationKey.SkippedOnboardingExtraConfig]: boolean;
  [ConfigurationKey.IgnoredImmichDatabaseDumpWarning]: boolean;
  [ConfigurationKey.ResticOptionRestConnections]: number;
  [ConfigurationKey.SessionSecret]: string;
  [ConfigurationKey.StatePath]: string;
  [ConfigurationKey.ThrottleBytesPerSec]: number;
  [ConfigurationKey.ThrottleQuietHours]: string;
};

@Table({ name: 'futo_backups_config' })
export class ConfigTable<Key extends ConfigurationKey = ConfigurationKey> {
  @PrimaryColumn({ type: 'enum', enum: configuration_key_enum })
  key!: Key;

  @Column({ type: 'jsonb' })
  value!: ConfigurationValues[Key];
}
