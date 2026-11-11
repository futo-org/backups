import {
  type ErrorMessage,
  ResticBackupCommandCouldNotReadSourceDataError,
  TryParseError,
} from '@futo-org/restic-wrapper';
import { ServiceUnavailableException } from '@nestjs/common';
import { JobStatus, TaskStatus } from '../enum.js';

export const RESTIC_NOT_FOUND_MESSAGE =
  'restic was not found on PATH. Your Immich image does not include it; use the official Immich image or the FUTO Backups standalone container.';

export class ResticNotFoundError extends ServiceUnavailableException {
  constructor() {
    super(RESTIC_NOT_FOUND_MESSAGE);
  }
}

export function explainMissingRestic(error: unknown): never {
  const { code, path } = (error ?? {}) as { code?: unknown; path?: unknown };
  if (code === 'ENOENT' && path === 'restic') {
    throw new ResticNotFoundError();
  }

  throw error;
}

export class TaskCancelledError extends Error {
  constructor() {
    super('Cancelled by user action');
  }
}

export class TaskWarningsError extends AggregateError {
  constructor(errors: Error[]) {
    super(errors, 'Task finished with warnings');
  }
}

export function isNotFoundError(error: unknown) {
  return (error as { status?: number } | undefined)?.status === 404;
}

export function getTaskStatus(error?: unknown): TaskStatus {
  if (!error) {
    return TaskStatus.Complete;
  }

  if (error instanceof TaskCancelledError) {
    return TaskStatus.Cancelled;
  }

  if (error instanceof ResticBackupCommandCouldNotReadSourceDataError || error instanceof TaskWarningsError) {
    return TaskStatus.Warn;
  }

  return TaskStatus.Failed;
}

export function getJobStatus(error?: unknown): JobStatus {
  if (!error) {
    return JobStatus.Complete;
  }

  if (error instanceof TaskCancelledError) {
    return JobStatus.Cancelled;
  }

  if (error instanceof ResticBackupCommandCouldNotReadSourceDataError || error instanceof TaskWarningsError) {
    return JobStatus.Warn;
  }

  return JobStatus.Failed;
}

export function writeError(log: (event: ErrorMessage) => void, error: unknown) {
  if (error instanceof AggregateError) {
    for (const innerError of error.errors) {
      writeError(log, innerError);
    }

    return;
  }

  const events =
    error instanceof TryParseError && Array.isArray(error.error)
      ? error.error
      : [{ message_type: 'error' as const, error: { message: `${error}` } }];

  for (const event of events) {
    log(event);
  }
}
