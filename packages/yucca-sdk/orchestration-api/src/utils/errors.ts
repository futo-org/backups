import {
  type ErrorMessage,
  ResticBackupCommandCouldNotReadSourceDataError,
  TryParseError,
} from '@futo-org/restic-wrapper';
import { JobStatus, TaskStatus } from '../enum.js';

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
