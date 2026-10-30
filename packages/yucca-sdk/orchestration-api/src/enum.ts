export enum CookieName {
  NextUrl = 'sdk-next',
  OidcState = 'sdk-oidc-state',
  OidcCodeVerifier = 'sdk-oidc-code-verifier',
  SessionToken = 'sdk-session',
  YuccaAccessToken = 'yucca-access-token',
  YuccaOidcState = 'yucca-oidc-state',
  YuccaOidcCodeVerifier = 'yucca-oidc-code-verifier',
}

export enum ImmichCookie {
  MaintenanceToken = 'immich_maintenance_token',
}

export enum TicketAction {
  DeleteRepository = 'repository.delete',
  DisableWorm = 'repository.disable-worm',
}

export enum ConfigurationKey {
  EncryptionKey = 'encryption-key',
  OnboardedKey = 'onboarded-key',
  Telemetry = 'telemetry',
  SkippedOnboardingExtraConfig = 'skipped-onboarding-extra-config',
  IgnoredImmichDatabaseDumpWarning = 'ignored-immich-database-dump-warning',
  ResticOptionRestConnections = 'restic-o-rest-connections',
  SessionSecret = 'session-secret',
  StatePath = 'state-path',
  ThrottleBytesPerSec = 'throttle-bytes-per-sec',
  ThrottleQuietHours = 'throttle-quiet-hours',
  SupportMode = 'support-mode',
  RestoreAwaitingContinue = 'restore-awaiting-continue',
}

export enum MetadataKey {
  PublicRoute = 'public-route',
  JobConfig = 'job-config',
}

export enum BackendType {
  Yucca = 'yucca',
  Local = 'local',
  S3 = 's3',
}

export enum TaskStatus {
  Incomplete = 'incomplete',
  Complete = 'complete',
  Warn = 'warn',
  Failed = 'failed',
  Cancelled = 'cancelled',
}

export enum JobName {
  RepositoryBackup = 'repository-backup',
  RepositoryPrune = 'repository-prune',
  RepositoryRestore = 'repository-restore',
  RepositoryRestoreFromPoint = 'repository-restore-from-point',
  RepositorySnapshotForget = 'repository-snapshot-forget',
  RepositorySyncMetrics = 'repository-sync-metrics',
}

export enum JobStatus {
  Queued = 'queued',
  Running = 'running',
  Complete = 'complete',
  Warn = 'warn',
  Failed = 'failed',
  Cancelled = 'cancelled',
  Incomplete = 'incomplete',
}

export enum InternalEvent {
  ModuleConfigUpdated = 'yucca.moduleConfig.updated',
}

export enum DeviceFlowEventType {
  Start = 'START',
  Success = 'SUCCESS',
  Failure = 'FAILURE',
}

export enum DeviceFlowFailureReason {
  NotConnected = 'NOT_CONNECTED',
  DeviceFlowFailed = 'DEVICE_FLOW_FAILED',
  WrongAccount = 'WRONG_ACCOUNT',
  Unknown = 'UNKNOWN',
}

export enum BootstrapStatus {
  NotReady = 'not-ready',
  Ready = 'ready',
  Error = 'error',
}

export enum TelemetryLevel {
  Full = 'full',
  None = 'none',
}

export enum ResticTagPrefix {
  ImmichBackupFileName = 'yucca.v1.immichBackupFileName',
}
