/**
 * yucca
 * 1.0.0
 * DO NOT MODIFY - This file has been generated using oazapfts.
 * See https://www.npmjs.com/package/oazapfts
 */
import * as Oazapfts from "@oazapfts/runtime";
import * as QS from "@oazapfts/runtime/query";
export const defaults: Oazapfts.Defaults<Oazapfts.CustomHeaders> = {
    headers: {},
    baseUrl: "/"
};
const oazapfts = Oazapfts.runtime(defaults);
export const servers = {};
export type DeviceFlowEventType = "START" | "SUCCESS" | "FAILURE";
export type DeviceFlowFailureReason = "NOT_CONNECTED" | "DEVICE_FLOW_FAILED" | "WRONG_ACCOUNT" | "UNKNOWN";
export type DeviceFlowEventDto = {
    "type": DeviceFlowEventType;
    userCode?: string;
    verificationUri?: string;
    token?: string;
    backendId?: string;
    reason?: DeviceFlowFailureReason;
};
export type CreateSessionRequestDto = {
    token: string;
};
export type TicketAction = "repository.delete" | "repository.disable-worm";
export type TicketCreateRequestDto = {
    action: TicketAction;
    /** Repository the ticket is bound to */
    repositoryId: string;
};
export type TicketCreateResponseDto = {
    /** Identity provider URL the browser must be sent to */
    redirectTo: string;
};
export type BackendType = "yucca" | "local" | "s3";
export type BackendDto = {
    id: string;
    "type": BackendType;
    description: string;
    isOnline: boolean;
    error?: string;
};
export type BackendsResponseDto = {
    backends: BackendDto[];
};
export type CreateLocalBackendRequestDto = {
    path: string;
};
export type BackendResponseDto = {
    backend: BackendDto;
};
export type BandwidthDto = {
    bytesPerSec: number;
    quietHours?: string;
};
export type ConfigResponseDto = {
    bandwidth: BandwidthDto;
};
export type ConfigUpdateRequestDto = {
    bandwidth: BandwidthDto;
};
export type FilesystemListingItemDto = {
    path: string;
    isDirectory: boolean;
};
export type FilesystemListingResponseDto = {
    parent: string;
    path: string;
    items: FilesystemListingItemDto[];
};
export type ImmichLibraryDto = {
    id: string;
    name: string;
    importPaths: string[];
    exclusionPatterns: string[];
};
export type ImmichStateDto = {
    dataPath: string;
    dataFolders: string[];
    libraries: ImmichLibraryDto[];
};
export type ImmichIntegrationConfigurationDto = {
    dataFolders: string[];
    backupConfiguration: boolean;
    /** IDs of the external libraries to back up. Use ["all"] to back up every library, including ones added later. */
    libraries: string[];
};
export type ImmichIntegrationDto = {
    id: string;
    scheduleId: string;
    configuration: ImmichIntegrationConfigurationDto;
};
export type IntegrationsResponseDto = {
    immichState?: ImmichStateDto;
    immichIntegration?: ImmichIntegrationDto;
};
export type BackupStatus = "incomplete" | "complete" | "warn" | "failed" | "cancelled";
export type RepositoryMetricsDto = {
    lastStarted?: string | null;
    lastBackup?: string | null;
    lastBackupStatus?: (BackupStatus) | null;
    lastBackupDuration?: number | null;
    sizeBytes: number;
};
export type RepositoryMeterDto = {
    sizeBytes: number;
    objectCount: number;
    lastUpdated?: string | null;
};
export type RepositoryBackendDto = {
    id: string;
    "type": BackendType;
    online: boolean;
};
export type RepositoryBackendsDto = {
    primary: RepositoryBackendDto;
    secondary: RepositoryBackendDto[];
};
export type RetentionPolicyDto = {
    keepLast?: number;
    keepWithin?: string;
    keepWithinHourly?: string;
    keepWithinDaily?: string;
    keepWithinWeekly?: string;
    keepWithinMonthly?: string;
    keepWithinYearly?: string;
};
export type RepositoryConfigurationDto = {
    paths: string[];
    retentionPolicy?: (RetentionPolicyDto) | null;
};
export type LocalRepositoryDto = {
    id: string;
    worm: boolean;
    name: string;
    siteCode: string | null;
    storageClusterCode: string | null;
    metrics: RepositoryMetricsDto;
    meter?: RepositoryMeterDto;
    backends?: RepositoryBackendsDto;
    configuration?: RepositoryConfigurationDto;
};
export type ScheduleDto = {
    id: string;
    name: string;
    paused: boolean;
    cron: string;
    repositories: string[];
    lastRun?: string;
    lastFinished?: string;
};
export type JobName = "repository-backup" | "repository-prune" | "repository-restore" | "repository-restore-from-point" | "repository-snapshot-forget" | "repository-sync-metrics";
export type JobStatus = "queued" | "running" | "complete" | "warn" | "failed" | "cancelled" | "incomplete";
export type JobProgressDto = {
    percentDone: number;
    secondsRemaining?: number;
    bytesDone?: number;
    totalBytes?: number;
    currentFiles: string[];
};
export type JobSummaryDto = {
    "type": "backup";
    filesNew: number;
    filesChanged: number;
    totalFilesProcessed: number;
    totalBytesProcessed: number;
    snapshotId?: string;
} | {
    "type": "restore";
    filesRestored: number;
    filesSkipped: number;
    bytesRestored: number;
} | {
    "type": "prune";
    kept: number;
    removed: number;
};
export type JobOutcomeDto = {
    errors: string[];
    summary?: JobSummaryDto;
};
export type JobDto = {
    id: string;
    name: JobName;
    repositoryId: string;
    status: JobStatus;
    queuedAt: string;
    start?: string;
    end?: string;
    progress?: JobProgressDto;
    outcome?: JobOutcomeDto;
};
export type ImmichDatabaseDumpConfigDto = {
    enabled: boolean;
    keepLastAmount: number;
};
export type ImmichBackupStatusDto = {
    integration?: ImmichIntegrationDto;
    repository?: LocalRepositoryDto;
    backend?: BackendDto;
    schedule?: ScheduleDto;
    latestBackupJob?: JobDto;
    databaseDump?: ImmichDatabaseDumpConfigDto;
    databaseDumpWarningIgnored?: boolean;
};
export type ConfigureImmichIntegrationRequestDto = {
    name: string;
    worm: boolean;
    cron: string;
    dataFolders: string[];
    backupConfiguration: boolean;
    /** IDs of the external libraries to back up. Use ["all"] to back up every library, including ones added later. */
    libraries: string[];
    retentionPolicy?: (RetentionPolicyDto) | null;
    paused?: boolean;
    repositoryId?: string;
};
export type ConfigureImmichIntegrationResponseDto = {
    repositoryId: string;
};
export type ConfigureImmichDatabaseDumpRequestDto = {
    enabled?: boolean;
    keepLastAmount?: number;
};
export type ImmichRollbackRequestDto = {
    repositoryId: string;
    snapshotId: string;
    backupFileName?: string;
};
export type JobListResponseDto = {
    jobs: JobDto[];
};
export type BootstrapStatus = "not-ready" | "ready" | "error";
export type TelemetryLevel = "full" | "none";
export type OnboardingStatusResponseDto = {
    status: BootstrapStatus;
    error?: string;
    hasTelemetry: TelemetryLevel;
    requiresAuthentication: boolean;
    isAuthenticated: boolean;
    hasOnboardedKey: boolean;
    hasBackend: boolean;
    hasBackup: boolean;
    hasSchedule: boolean;
    hasSkippedExtraConfig: boolean;
};
export type CurrentRecoveryKeyResponse = {
    recoveryKey: string;
};
export type ImportRecoveryKeyRequest = {
    recoveryKey: string;
};
export type RepositoryCreateRequestDto = {
    name: string;
    worm: boolean;
    /** Internal site code from environment metadata */
    site?: string;
    paths?: string[];
    retentionPolicy?: (RetentionPolicyDto) | null;
};
export type RepositoryCreateResponseDto = {
    repository: LocalRepositoryDto;
};
export type RepositoryListResponseDto = {
    repositories: LocalRepositoryDto[];
};
export type SnapshotSummaryDto = {
    filesNew: number;
    filesChanged: number;
    filesUnmodified: number;
    totalFiles: number;
    totalBytes: number;
    dataAdded: number;
};
export type SnapshotDto = {
    id: string;
    time: string;
    paths: string[];
    tags?: string[];
    summary?: SnapshotSummaryDto;
};
export type InspectedLocalRepositoryDto = {
    id: string;
    worm: boolean;
    name: string;
    siteCode: string | null;
    storageClusterCode: string | null;
    metrics: RepositoryMetricsDto;
    meter?: RepositoryMeterDto;
    backends?: RepositoryBackendsDto;
    configuration?: RepositoryConfigurationDto;
    snapshots?: SnapshotDto[];
};
export type RepositoryInspectResponseDto = {
    repositories: InspectedLocalRepositoryDto[];
};
export type RepositoryUpdateRequestDto = {
    name?: string;
    worm?: boolean;
    paths?: string[];
    retentionPolicy?: (RetentionPolicyDto) | null;
};
export type RepositoryUpdateResponseDto = {
    repository: LocalRepositoryDto;
};
export type JobResponseDto = {
    jobId: string;
};
export type RepositorySyncDeletionResponseDto = {
    /** Whether the repository was deleted remotely and removed from this server */
    deleted: boolean;
};
export type RepositoryCheckImportResponseDto = {
    readable: boolean;
};
export type RepositoryPrimaryBackendReconfigureRequestDto = {
    backendId: string;
};
export type ListSnapshotsResponseDto = {
    snapshots: SnapshotDto[];
};
export type RepositorySnapshotRestoreRequestDto = {
    target?: string;
    include?: string[];
};
export type RepositorySnapshotRestoreFromPointRequestDto = {
    yuccaConfig?: string;
    include?: string[];
};
export type ScheduleCreateRequestDto = {
    name: string;
    paused?: boolean;
    cron: string;
    repositories: string[];
};
export type ScheduleCreateResponseDto = {
    schedule: ScheduleDto;
};
export type ScheduleListResponseDto = {
    schedules: ScheduleDto[];
};
export type ScheduleUpdateRequestDto = {
    name?: string;
    paused?: boolean;
    cron?: string;
    repositories?: string[];
};
export type ScheduleUpdateResponseDto = {
    schedule: ScheduleDto;
};
/**
 * Connect a FUTO Backups account
 */
export function connectDeviceFlow(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: DeviceFlowEventDto;
    }>("/api/yucca/auth/oidc/device", {
        ...opts
    }));
}
/**
 * Sign in with FUTO Backups account
 */
export function sessionDeviceFlow(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: DeviceFlowEventDto;
    }>("/api/yucca/auth/session/device", {
        ...opts
    }));
}
/**
 * Create session
 */
export function createSession(createSessionRequestDto: CreateSessionRequestDto, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchText("/api/yucca/auth/session", oazapfts.json({
        ...opts,
        method: "POST",
        body: createSessionRequestDto
    })));
}
/**
 * Create a ticket
 */
export function createTicket(ticketCreateRequestDto: TicketCreateRequestDto, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 201;
        data: TicketCreateResponseDto;
    }>("/api/yucca/auth/ticket", oazapfts.json({
        ...opts,
        method: "POST",
        body: ticketCreateRequestDto
    })));
}
/**
 * List backends
 */
export function getBackends(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: BackendsResponseDto;
    }>("/api/yucca/backend", {
        ...opts
    }));
}
/**
 * Create a local backend
 */
export function createLocalBackend(createLocalBackendRequestDto: CreateLocalBackendRequestDto, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 201;
        data: BackendResponseDto;
    }>("/api/yucca/backend/local", oazapfts.json({
        ...opts,
        method: "POST",
        body: createLocalBackendRequestDto
    })));
}
/**
 * Get backups orchestrator configuration
 */
export function getConfig(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: ConfigResponseDto;
    }>("/api/yucca/config", {
        ...opts
    }));
}
/**
 * Update backups orchestrator configuration
 */
export function updateConfig(configUpdateRequestDto: ConfigUpdateRequestDto, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: ConfigResponseDto;
    }>("/api/yucca/config", oazapfts.json({
        ...opts,
        method: "PUT",
        body: configUpdateRequestDto
    })));
}
/**
 * Reset the backups orchestrator
 */
export function resetOrchestrator(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchText("/api/yucca/debug/reset", {
        ...opts,
        method: "POST"
    }));
}
/**
 * List files
 */
export function getFileListing({ path }: {
    path?: string;
} = {}, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: FilesystemListingResponseDto;
    }>(`/api/yucca/fs${QS.query(QS.explode({
        path
    }))}`, {
        ...opts
    }));
}
/**
 * Get backup integrations
 */
export function getIntegrations(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: IntegrationsResponseDto;
    }>("/api/yucca/integrations", {
        ...opts
    }));
}
/**
 * Get Immich backup status
 */
export function getImmichBackupStatus(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: ImmichBackupStatusDto;
    }>("/api/yucca/integrations/immich/status", {
        ...opts
    }));
}
/**
 * Configure the Immich backup integration
 */
export function configureImmichIntegration(configureImmichIntegrationRequestDto: ConfigureImmichIntegrationRequestDto, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 201;
        data: ConfigureImmichIntegrationResponseDto;
    }>("/api/yucca/integrations/immich", oazapfts.json({
        ...opts,
        method: "POST",
        body: configureImmichIntegrationRequestDto
    })));
}
/**
 * Ignore the Immich database dump warning
 */
export function ignoreImmichDatabaseDumpWarning(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchText("/api/yucca/integrations/immich/database-dump/ignore-warning", {
        ...opts,
        method: "POST"
    }));
}
/**
 * Configure Immich database dumps
 */
export function configureImmichDatabaseDump(configureImmichDatabaseDumpRequestDto: ConfigureImmichDatabaseDumpRequestDto, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchText("/api/yucca/integrations/immich/database-dump", oazapfts.json({
        ...opts,
        method: "POST",
        body: configureImmichDatabaseDumpRequestDto
    })));
}
/**
 * Roll Immich back to a snapshot
 */
export function startImmichRollback(immichRollbackRequestDto: ImmichRollbackRequestDto, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchText("/api/yucca/integrations/immich/rollback", oazapfts.json({
        ...opts,
        method: "POST",
        body: immichRollbackRequestDto
    })));
}
/**
 * List jobs
 */
export function getJobs(repositoryId: string, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: JobListResponseDto;
    }>(`/api/yucca/jobs${QS.query(QS.explode({
        repositoryId
    }))}`, {
        ...opts
    }));
}
/**
 * Get a job
 */
export function getJob(id: string, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: JobDto;
    }>(`/api/yucca/jobs/${encodeURIComponent(id)}`, {
        ...opts
    }));
}
/**
 * Cancel a job
 */
export function cancelJob(id: string, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchText(`/api/yucca/jobs/${encodeURIComponent(id)}`, {
        ...opts,
        method: "DELETE"
    }));
}
/**
 * Download a job log
 */
export function downloadJobLog(id: string, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchBlob<{
        status: 200;
        data: Blob;
    }>(`/api/yucca/jobs/${encodeURIComponent(id)}/download`, {
        ...opts
    }));
}
/**
 * Get backup onboarding status
 */
export function onboardingStatus(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: OnboardingStatusResponseDto;
    }>("/api/yucca/onboarding", {
        ...opts
    }));
}
/**
 * Get the backup recovery key
 */
export function currentRecoveryKey(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: CurrentRecoveryKeyResponse;
    }>("/api/yucca/onboarding/recovery-key", {
        ...opts
    }));
}
/**
 * Import a backup recovery key
 */
export function importRecoveryKey(importRecoveryKeyRequest: ImportRecoveryKeyRequest, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchText("/api/yucca/onboarding/recovery-key", oazapfts.json({
        ...opts,
        method: "PUT",
        body: importRecoveryKeyRequest
    })));
}
/**
 * Confirm the backup recovery key
 */
export function confirmRecoveryKey(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchText("/api/yucca/onboarding/recovery-key", {
        ...opts,
        method: "POST"
    }));
}
/**
 * Skip optional backup onboarding
 */
export function skipOnboardingExtraConfig(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchText("/api/yucca/onboarding/skip", {
        ...opts,
        method: "POST"
    }));
}
/**
 * Enable FUTO Backups telemetry
 */
export function enableTelemetry(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchText("/api/yucca/onboarding/telemetry", {
        ...opts,
        method: "POST"
    }));
}
/**
 * Report a startup error
 */
export function reportError(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchText("/api/yucca/onboarding/report-error", {
        ...opts,
        method: "POST"
    }));
}
/**
 * Create a new backup
 */
export function createRepository(repositoryCreateRequestDto: RepositoryCreateRequestDto, { backend }: {
    backend?: string;
} = {}, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 201;
        data: RepositoryCreateResponseDto;
    }>(`/api/yucca/repository${QS.query(QS.explode({
        backend
    }))}`, oazapfts.json({
        ...opts,
        method: "POST",
        body: repositoryCreateRequestDto
    })));
}
/**
 * List backups
 */
export function getRepositories(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: RepositoryListResponseDto;
    }>("/api/yucca/repository", {
        ...opts
    }));
}
/**
 * List remote backups
 */
export function inspectRepositories({ backend }: {
    backend?: string;
} = {}, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: RepositoryInspectResponseDto;
    }>(`/api/yucca/repository/inspect${QS.query(QS.explode({
        backend
    }))}`, {
        ...opts
    }));
}
/**
 * Update a backup
 */
export function updateRepository(id: string, repositoryUpdateRequestDto: RepositoryUpdateRequestDto, { backend }: {
    backend?: string;
} = {}, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: RepositoryUpdateResponseDto;
    }>(`/api/yucca/repository/${encodeURIComponent(id)}${QS.query(QS.explode({
        backend
    }))}`, oazapfts.json({
        ...opts,
        method: "PATCH",
        body: repositoryUpdateRequestDto
    })));
}
/**
 * Remove a backup
 */
export function deleteRepository(id: string, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchText(`/api/yucca/repository/${encodeURIComponent(id)}`, {
        ...opts,
        method: "DELETE"
    }));
}
/**
 * Start a backup
 */
export function createBackup(id: string, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 201;
        data: JobResponseDto;
    }>(`/api/yucca/repository/${encodeURIComponent(id)}`, {
        ...opts,
        method: "POST"
    }));
}
/**
 * Sync a remote deletion
 */
export function syncRepositoryDeletion(id: string, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 201;
        data: RepositorySyncDeletionResponseDto;
    }>(`/api/yucca/repository/${encodeURIComponent(id)}/sync-deletion`, {
        ...opts,
        method: "POST"
    }));
}
/**
 * Check a repository import
 */
export function checkImportRepository(id: string, backend: string, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: RepositoryCheckImportResponseDto;
    }>(`/api/yucca/repository/${encodeURIComponent(id)}/import${QS.query(QS.explode({
        backend
    }))}`, {
        ...opts
    }));
}
/**
 * Import a repository
 */
export function importRepository(id: string, backend: string, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 201;
        data: RepositoryCreateResponseDto;
    }>(`/api/yucca/repository/${encodeURIComponent(id)}/import${QS.query(QS.explode({
        backend
    }))}`, {
        ...opts,
        method: "POST"
    }));
}
/**
 * Change the primary backend
 */
export function reconfigureRepositoryPrimaryBackend(id: string, repositoryPrimaryBackendReconfigureRequestDto: RepositoryPrimaryBackendReconfigureRequestDto, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: RepositoryCreateResponseDto;
    }>(`/api/yucca/repository/${encodeURIComponent(id)}/backend`, oazapfts.json({
        ...opts,
        method: "PUT",
        body: repositoryPrimaryBackendReconfigureRequestDto
    })));
}
/**
 * List snapshots
 */
export function getSnapshots(id: string, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: ListSnapshotsResponseDto;
    }>(`/api/yucca/repository/${encodeURIComponent(id)}/snapshots`, {
        ...opts
    }));
}
/**
 * Prune a repository
 */
export function pruneRepository(id: string, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 201;
        data: JobResponseDto;
    }>(`/api/yucca/repository/${encodeURIComponent(id)}/snapshots/prune`, {
        ...opts,
        method: "POST"
    }));
}
/**
 * Restore a snapshot
 */
export function restoreSnapshot(id: string, snapshot: string, repositorySnapshotRestoreRequestDto: RepositorySnapshotRestoreRequestDto, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 201;
        data: JobResponseDto;
    }>(`/api/yucca/repository/${encodeURIComponent(id)}/snapshots/${encodeURIComponent(snapshot)}`, oazapfts.json({
        ...opts,
        method: "POST",
        body: repositorySnapshotRestoreRequestDto
    })));
}
/**
 * Delete a snapshot
 */
export function forgetSnapshot(id: string, snapshot: string, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: ListSnapshotsResponseDto;
    }>(`/api/yucca/repository/${encodeURIComponent(id)}/snapshots/${encodeURIComponent(snapshot)}`, {
        ...opts,
        method: "DELETE"
    }));
}
/**
 * Restore from snapshot
 */
export function restoreFromPoint(id: string, snapshot: string, backend: string, repositorySnapshotRestoreFromPointRequestDto: RepositorySnapshotRestoreFromPointRequestDto, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 201;
        data: JobResponseDto;
    }>(`/api/yucca/repository/${encodeURIComponent(id)}/snapshots/${encodeURIComponent(snapshot)}/restore-from-point${QS.query(QS.explode({
        backend
    }))}`, oazapfts.json({
        ...opts,
        method: "POST",
        body: repositorySnapshotRestoreFromPointRequestDto
    })));
}
/**
 * List snapshot files
 */
export function getSnapshotListing(id: string, snapshot: string, { path }: {
    path?: string;
} = {}, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: FilesystemListingResponseDto;
    }>(`/api/yucca/repository/${encodeURIComponent(id)}/snapshots/${encodeURIComponent(snapshot)}/listing${QS.query(QS.explode({
        path
    }))}`, {
        ...opts
    }));
}
/**
 * Create a schedule
 */
export function createSchedule(scheduleCreateRequestDto: ScheduleCreateRequestDto, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 201;
        data: ScheduleCreateResponseDto;
    }>("/api/yucca/schedule", oazapfts.json({
        ...opts,
        method: "POST",
        body: scheduleCreateRequestDto
    })));
}
/**
 * List schedules
 */
export function getSchedules(opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: ScheduleListResponseDto;
    }>("/api/yucca/schedule", {
        ...opts
    }));
}
/**
 * Update a schedule
 */
export function updateSchedule(id: string, scheduleUpdateRequestDto: ScheduleUpdateRequestDto, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchJson<{
        status: 200;
        data: ScheduleUpdateResponseDto;
    }>(`/api/yucca/schedule/${encodeURIComponent(id)}`, oazapfts.json({
        ...opts,
        method: "PATCH",
        body: scheduleUpdateRequestDto
    })));
}
/**
 * Delete a schedule
 */
export function removeSchedule(id: string, opts?: Oazapfts.RequestOpts) {
    return oazapfts.ok(oazapfts.fetchText(`/api/yucca/schedule/${encodeURIComponent(id)}`, {
        ...opts,
        method: "DELETE"
    }));
}
