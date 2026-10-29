# Support logs

Support mode lets a user (or FUTO support, walking them through it) capture what restic
actually does on their machine, and optionally stream it to FUTO.

## Client (orchestration-api)

- **Support mode** is a client setting (`PUT /futo-backups/support-mode`): a number of remaining
  runs, plus `streamToFuto` and `includePaths`. Backup, prune, restore and snapshot-forget
  jobs each spend one run; metrics syncs never do. At zero it is off.
- A job in support mode runs every restic command with `--verbose=2` and records every raw
  stdout and stderr line (live, including retries) to `logs/jobs/<id>.support.jsonl`
  beside the job log, downloadable from the job's history. That local copy is never
  redacted and needs no feature flag.
- **Streaming** additionally needs the `support-log-streaming` feature flag on the FUTO
  account. The client opens a session with yucca-api, then ships gzipped NDJSON batches to
  the streamer. It never slows restic: lines go into a bounded in-memory buffer (64 MiB)
  and are dropped, and counted, when it is full or a batch keeps failing. The count travels
  with the next batch and ends up on the session as `droppedLineCount`.
- With `includePaths` off, every absolute path is replaced by `<path:<hmac>.<ext>>` before
  it leaves the machine. The HMAC key is random per session, so a path maps to the same
  placeholder within one session only.
- The job's outcome carries `support.sessionId`: the support code shown to the user.

## Server

- `POST /api/support-logs/sessions` (`@RequireFeature('support-log-streaming')`) records a
  `supportLogSessions` row and returns `{ id, token, url, expiresAt }`. The token is an
  ES256 JWT signed with `JWT_PRIVATE_KEY`, `aud: support-logs`, `sub` the user, `sid` the
  session, valid 6 h; clients refresh it through `POST /api/support-logs/sessions/:id/token`,
  which re-checks the flag, so clearing the flag stops a stream within one refresh.
  `url` comes from `SUPPORT_LOGS_URL`; unset, sessions are refused with 503.
- The URL is handed out here rather than through the well-known documents because shipped
  SDKs parse those with `.strict()` and reject any new key.
- `support-logs-streamer` verifies the token offline with `JWT_PUBLIC_KEY`, exports each
  batch to VictoriaLogs over OTLP before acknowledging it (503 tells the client to retry),
  and reports per-session increments to `POST /api/internal/support-logs/sessions/:id/stats`
  (`X-Internal-Secret`). Each report has a `reportId` that it keeps across retries, and
  yucca-api applies each id once (`supportLogSessionReports`), so a retry after a lost
  response is not counted twice.
- Records carry `user` and `customerId` (so columbo's per-user scope matches),
  `support_session`, `connection`, `job`, `job_name`, `command`, `stream` and `batch_seq`.
  A retried batch can appear twice; `batch_seq` tells the copies apart.

## Finding a session

- `GET /user/:id/support-log-sessions` on yucca-admin-api lists a user's sessions with
  their line, byte, batch and dropped counts.
- In VictoriaLogs: `support_session:="<support code>"`.
