# Restic client retry behavior

What the restic client does when michael returns an error. Michael's own
resilience mechanisms (the S3 backend pool, its retries and circuit breakers)
are designed around this contract, so status-code decisions in
`packages/michael` should be checked against this document — and this document
against restic's source when it moves.

Sourced from restic `internal/backend/retry/backend_retry.go` and
`internal/backend/rest/rest.go` as of August 2026 (restic ≥ 0.17 semantics; the
`backend-error-redesign` feature flag is Beta and therefore **on by default**).

## The retry envelope

Every backend operation (Load, Save, Stat, Remove, List) is wrapped in a retry
layer: exponential backoff starting at 1s, doubling per attempt, capped at 60s
per interval, retrying until **15 minutes** have elapsed (hardcoded). There is
no attempt cap. A cancelled context aborts immediately.

Consequences for michael:

- An outage shorter than ~15 minutes is invisible to users **if** michael fails
  fast: the operation succeeds on a later retry and the backup completes.
- Every response that hangs (e.g. waiting on a dead gateway's dial timeout)
  burns the client's fixed 15-minute window without advancing it.

## Permanent vs retryable status codes

`IsPermanentError` for the REST backend: **404, 401, 403, 416, 507** abort the
operation immediately. Everything else — 500, 502, **503**, timeouts, resets,
any transport error — is retried for the full window.

| michael returns | restic does |
|---|---|
| 500 / 503 | retries with backoff, up to 15 min |
| 403 (WORM violation, "already exists") | fails the operation permanently |
| 404 on HEAD | treats as "does not exist" (permanent, but often the expected answer) |
| 404 on GET | "does not exist", permanent; never trips the per-file breaker below. A lock deleted between list and load is re-listed within seconds — a 500 here instead burns the full 15-minute window first |
| 400 | retried (not in the permanent set) — avoid for terminal conditions |

Restic does **not** read `Retry-After`; its backoff is fixed client-side. The
header is still worth sending for other clients, but it cannot pace restic.

## The per-file Load breaker

Restic keeps its own circuit breaker per file: a `Load` that exhausts retries
on a *non-permanent* error marks that file failed for **one hour**, and every
further read of it fails instantly. A transient gateway blip surfaced as a 500
can therefore lock a client out of a pack file for an hour mid-restore — which
is why michael masks single-gateway failures instead of forwarding them.

## Save failure recovery, and the WORM trap

On a failed `Save`, restic issues a cleanup `Remove` for the possibly-partial
upload (errors ignored — rest-server reports `HasAtomicReplace=false`), rewinds
its pack (restic's own body IS seekable) and re-POSTs.

On a WORM repository this recovery used to be a trap. If the failure was
*ambiguous* — michael reported an error but the gateway committed the object:

1. the cleanup `Remove` is refused (WORM forbids deleting data blobs);
2. the re-POST hits the `If-None-Match: *` precondition → 412;
3. michael surfaced that as 403 "Blob already exists";
4. 403 is permanent → the backup failed hard, with the blob stored correctly.

Michael therefore converges this case: a write-once PUT that fails its
precondition, for a content-addressed key, where the existing object's size
matches the incoming one, returns 200 (see `S3Storage.PutObject`). Blob keys
are the content's sha256 and michael verified that hash when the object was
first written, so the size check identifies the same blob without re-reading
it. The config object's key is not content-addressed and is excluded.

## Save bodies vs michael's PUT path

Restic retries `Save` with a rewindable body — but the stream michael proxies
to S3 is **not** seekable, which is why the aws-sdk retryer is disabled on
michael's PUT path and michael never retries an upload itself: any transient
failure surfaces once, cleanly, and restic re-drives the upload end-to-end.

A storage failure on a request whose context is already cancelled (restic
killed, the link dropped, or the gateway resetting its upstream) is answered
499 whatever error the SDK surfaced first, the body's EOF included, and logged
at warn instead of error: blob save, load, HEAD, list and delete, config save,
load, HEAD and delete, repository create. Blob save and load, the two handlers
that count `storage.backend.errors`, leave that counter alone. Three cases
differ: a download that fails mid-stream still logs "error streaming response"
at error; a list whose response write or flush fails has already sent its 200
and is logged at warn only; and a list that fails after part of the body is
out has already sent its 200 too, so the handler logs the warn and panics with
`http.ErrAbortHandler` to truncate the response, and that panic also skips the
`http.server.request.count` increment in the metrics middleware, so the
request is missing from the series. The 499 stays in
`http.server.request.count` and `http.server.request.errors` (status >= 400)
but out of the `status=~"5.."` alerts: a 5xx there would read as "backups are
down" every time a client restarts. The pool asks a different question, is
this a backend signal: a failure on any context the caller ended, cancelled or
past its deadline, is not scored for or against the backend and is not counted
in `s3.backend.requests` or `s3.backend.errors`. The 499 itself is keyed on
the request context being cancelled, so a request that hit a deadline would
still be a 500 with the error log (and `storage.backend.errors` for blob save
and load) while leaving the backend's health score alone; nothing in michael
sets a request deadline today. michael cannot tell a client abort from an
envoy upstream reset, so a stalled RGW that envoy times out lands here too,
and pool health will not flag it either: the health probe treats its
own 5s timeout as a pass, so `s3.backend.healthy` stays 1. That case shows up
as time-to-first-byte (MichaelHighTTFB), as a climbing `s3.backend.inflight`
on the gateway, and as a 499 rate in `http.server.request.count`, not in the
5xx alerts.
