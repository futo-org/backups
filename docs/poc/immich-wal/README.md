# PoC: continuous, point-in-time-recoverable Postgres backups for Immich

Proof of concept for option (b) in [futo-org/backups#168](https://github.com/futo-org/backups/issues/168):
`pg_receivewal` streams WAL over the replication protocol into the Immich restic repository, nightly
`pg_basebackup` goes in through `restic backup --stdin-from-command`, and every library snapshot is tagged with the
LSN of a restore point taken just before its file walk. A restore never touches PGDATA. It recovers the base backup
and WAL into a scratch Postgres up to the target, then runs `pg_dump` and loads the output into the live database.

Only the Immich integration is covered. The module takes a connection and binaries, so a generic "Postgres WAL source"
can reuse it later.

## What is here

| Path                                                                                 | What                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `packages/yucca-sdk/orchestration-api/src/services/immichWal.service.ts`             | Manages the physical slot (`futo_backups`) and sets `max_slot_wal_keep_size` with `ALTER SYSTEM` plus `pg_reload_conf()`. Supervises `pg_receivewal` into `<stagingPath>/receive`, ships completed segments, timeline histories and (when changed) the `.partial` segment as `immich-wal` snapshots, and prunes what restic holds. Takes base backups and prepares snapshots. |
| `packages/yucca-sdk/orchestration-api/src/repositories/postgres.repository.ts`       | Runs `psql`, `pg_receivewal` and `pg_basebackup`. The password goes in a 0600 passfile in a private temp dir outside every backed-up path, referenced from the conninfo, never in argv or env (restic runs `--stdin-from-command` with only `PATH` and `HOME`). Queries take an AbortSignal plus a 60 s timeout.                                                                                                                                                  |
| `packages/yucca-sdk/orchestration-api/src/utils/wal.ts`                              | Pure helpers: LSN parsing and comparison, ship and prune selection, and `planWalRestore`: the newest completed base at or before the target, plus the WAL snapshots that continue its segment chain from the base's start segment. It rejects any target that lies past a missing segment.                                                                                                                                                                          |
| `packages/yucca-sdk/orchestration-api/src/repositories/restic.repository.ts`         | `backupFiles`, `backupCommandOutput` (`--stdin-from-command`), `addTags`, and a tag filter on `snapshots`.                                                                                                                                                                                                                                                 |
| `packages/yucca-sdk/orchestration-api/src/jobs/repositoryBackup.job.ts`              | When enabled, after the existing dump it takes a base backup if one is due, then calls `prepareSnapshot`: `pg_create_restore_point`, `pg_switch_wal()`, and a wait until that segment is in restic. It then tags the snapshot `yucca.v1.immichWalLsn=<lsn>`. Failures are warnings, as for the dump.                                                       |
| `packages/yucca-sdk/orchestration-api/src/services/repository.service.ts`            | Hides `immich-wal` and `immich-base` snapshots from snapshot listings and repository import.                                                                                                                                                                                                                                                               |
| `docs/poc/immich-wal/immich.patch`                                                   | The Immich side (`feat/futo-backups`): passes `walArchiving` (bin dir for the server's major version, connection, staging under `UPLOAD_LOCATION/backups/yucca-wal`) when `IMMICH_FUTO_BACKUPS_WAL_ARCHIVING=true`.                                                                                                                                        |
| `docs/poc/immich-wal/restore.mjs`                                                    | Restore tool: `--snapshot <id>`, `--lsn`, `--time` or `--latest`, then `--load-cmd '<psql …>'` or `--dump-to file.sql.gz`.                                                                                                                                                                                                                                 |
| `docs/poc/immich-wal/e2e.sh`, `driver.mjs`, `pg-shim.sh`                             | The end-to-end test. `driver.mjs` runs the real compiled `ImmichWalService`; `pg-shim.sh` runs the Postgres client binaries from the Immich postgres image.                                                                                                                                                                                                |

### Feature flag

The module only does something when `ImmichIntegration.walArchiving` is set. Immich sets it only when
`IMMICH_FUTO_BACKUPS_WAL_ARCHIVING=true` (see the patch). With it unset, the backup job takes exactly the existing
dump path; a unit test covers this. When it is on, the dump still runs, so today's restore path keeps working
alongside the new one.

### Snapshot layout in the repository

| Snapshot        | Tags                                                                                     | Content                                                     |
| --------------- | ---------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| base backup     | `immich-base`, `yucca.v1.immichWalBaseStart=<lsn>`, `yucca.v1.immichWalBaseStartSegment=<segment>`, `yucca.v1.immichWalBaseStop=<lsn>` | `/immich-base.tar` (the `pg_basebackup -Ft -D - -X none` stream) |
| WAL             | `immich-wal`, `yucca.v1.immichWalFirstSegment=…`, `yucca.v1.immichWalLastSegment=…`, `yucca.v1.immichWalPartialSegment=…` | one contiguous run of segment files (plus the `.partial`) at their staging paths |
| library         | existing tags, plus `yucca.v1.immichWalLsn=<lsn>`                                        | unchanged                                                   |

The stop tag is added with `restic tag` after the stream finishes. A base without it never completed and is ignored.

The staging dir holds a `CACHEDIR.TAG`, so the library backups' existing `--exclude-caches` skips the staged WAL and
`state.json`. `state.json` also records when a new base backup became required (first slot, or a lost slot was
recreated). That requirement survives restarts and clears only once a base that started afterwards has its stop tag.
Only 16 MB WAL segments are supported; the module refuses to start on anything else.

## Running the e2e

Needs Docker, plus `restic`, `node` and `jq` (mise provides the first two). From the repo root:

```bash
mise //packages/yucca-sdk/orchestration-api:build
mise exec -- docs/poc/immich-wal/e2e.sh
```

The script starts `restic/rest-server` (standing in for michael and the proxy) and
`ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` (Immich's pinned image). It shows that the stock
pg_hba rejects replication, appends `host replication postgres all scram-sha-256` and reloads, then:

1. Starts the module (slot plus `pg_receivewal`) and takes a base backup.
2. Writes rows A: 2000 `asset` rows plus 512-d `vector` embeddings, with vchord loaded.
3. Takes a library snapshot. This creates the restore point, switches WAL, waits for shipping, runs the file walk (which includes the staging dir) and tags it with LSN1. It checks that the snapshot holds only staging's `CACHEDIR.TAG`, with no `.pgpass` or WAL.
4. Records T1, then writes rows B. B reaches the repository only through the `.partial` segment.
5. Restores to LSN1, to T1 and to latest, each into a fresh database through a scratch Postgres plus `pg_dump`/`psql`.
6. Writes a `--dump-to` restore to a path with an apostrophe, a space and `$HOME` in it.
7. Kills the streamer, writes about 170 MB of WAL past the 64 MB cap and checks that the slot is `lost`. It then restarts the module and checks that it recreates the slot and that one more completed base backup appears in the repo.

It removes every container and anonymous volume it created (label `futo-wal-e2e`) and the temp dir, including on failure. A run takes about 70 seconds.

### Results (2026-11-04, this VM)

```
== Library snapshot: restore point, WAL switch, wait until shipped, then the file walk tagged with the LSN
LSN1=0/3596250 library snapshot=f2b7e5c3…
yucca.v1.immichWalLsn=0/3596250

== Restore to the library snapshot (LSN1=0/3596250) in a scratch Postgres, pg_dump into restored_lsn1
[restore] target {"lsn":"0/3596250"}: base be33e629 + 4 WAL snapshot(s)
[restore] scratch: recovery stopping after WAL location (LSN) "0/3596250"
restored_lsn1: A=2000 B=0 smart_search=2000

== Restore to the timestamp T1=2026-11-04T18:29:05.650Z
[restore] scratch: recovery stopping before commit of transaction 741, time 2026-11-04 18:29:07.768822+00
restored_time: A=2000 B=0 smart_search=2000

== Restore to the latest archived WAL
[restore] target "latest": base be33e629 + 7 WAL snapshot(s)
restored_latest: A=2000 B=2000 smart_search=4000

== Slot cap: stop the streamer and write well past max_slot_wal_keep_size=64MB
after:  active=false wal_status=lost restart_lsn=NULL WAL written since stop=168 MB
pg_wal: 12 files, 192 MB
Replication slot futo_backups lost WAL past max_slot_wal_keep_size, recreating it
```

### Measured WAL volume

| What                                                 | Bytes                                                                      |
| ---------------------------------------------------- | -------------------------------------------------------------------------- |
| WAL generated by the workload (4000 assets + embeddings) | 22.6 MB (`pg_wal_lsn_diff`), about 5.7 KB per asset                     |
| WAL snapshots (4 at that point)                      | 84 MB read (whole 16 MB segment files) → **10.5 MB added** to the repo     |
| Base backup of the fresh DB                          | 36 MB read → 4.1 MB added                                                  |

restic compression plus dedup of the zero-filled segment tails cuts WAL to about 0.46× its LSN volume. Most of the
volume is the embeddings (2 KB each) and full-page writes after each checkpoint. Every snapshot costs one extra, mostly
empty, segment because of `pg_switch_wal()`, which compresses to almost nothing. Real Immich numbers still need
telemetry (`pg_stat_wal.wal_bytes`), as #168 proposes.

### Slot cap behaviour

- **Cap works:** with the streamer dead, `max_slot_wal_keep_size` lets the next checkpoint drop the slot's WAL
  (`wal_status=lost`), so a dead orchestrator cannot fill the DB disk. pg_wal stayed at 192 MB after 168 MB of churn. What
  remains is recycled segments, which Immich's `max_wal_size = 5GB` bounds, not the slot. Without a cap (`-1`) the slot
  would pin everything since the streamer died.
- **Recovery after loss:** on restart the module detects `lost`. It ships whatever was still staged, drops and
  recreates the slot, discards the staged files and marks a base backup as required (the next backup job takes one).
  WAL between the loss and the new base is gone, so PITR into that window is impossible. Snapshots taken before the loss
  stay restorable from the older base.

## Known gaps

- **pg_hba opt-in.** Immich's image only adds `host all all all <auth>`, which does not match replication connections.
  The PoC appends a line with `docker exec` and reloads. The production path is a base-images env
  (`DB_ALLOW_REPLICATION=true`, appending `host replication <POSTGRES_USER> all <auth>` in the entrypoint). New compose
  files could default it on; existing installs have to opt in, which means a compose edit plus container recreate.
- **Restore needs a Postgres server binary.** The scratch instance is a `docker run` of the Immich postgres image. The
  immich-server image only ships the client tools, so the orchestrator cannot do this in-process today. Options: ship the
  `postgresql-<major>` server package in immich-server, run recovery as a sidecar or one-shot container, or use the
  user's DB container through a base-images hook.
- **Restore UX.** `restore.mjs` is a CLI. The production flow should be a `RepositoryRestoreFromPoint`-style job:
  recover, `--dump-to` an `immich-db-backup-<ts>-v<ver>-pg<ver>.sql.gz` in `UPLOAD_LOCATION/backups`, and hand that
  file name to the existing maintenance rollback (`enterMaintenanceRollback(repo, snapshot, backupFileName)`), so
  Immich's existing reset-schema plus `psql` restore runs unchanged. A time slider comes almost free (`--time` works).
- **Retention policy for WAL snapshots.** The prune job's `forgetByPolicy` groups by paths. Base snapshots
  (`/immich-base.tar`) form one group and follow the library policy, which is roughly right. WAL snapshots have unique
  paths, so `keep-last` never expires them: they grow without bound. A WAL-aware forget is needed that keeps every WAL
  snapshot newer than the oldest retained base (and the bases that library snapshots' LSNs depend on) and forgets the rest.
- **Prune lock contention.** Prune takes restic's exclusive lock. WAL ships fail during it and retry each tick; nothing is
  lost because staged files are only deleted after a successful snapshot, but staging grows. The backup job also runs
  `restic unlock --remove-all` before each run, which can remove a live WAL ship's lock. In the worst case that aborts
  the ship, and it is retried. `restic tag` for the base stop LSN needs the exclusive lock, so it uses `--retry-lock 5m`.
- **Snapshot count.** One WAL snapshot per minute when the DB is busy (the partial is re-shipped only when it changed),
  plus one or two per library snapshot. A day of steady writes is about 1440 snapshots. Listing filters them out, but
  repository index and snapshot-listing cost grow. Batch less often, or use `restic rewrite`/forget to merge.
- **PG14 resume gotcha.** On PG14, when its directory is empty, `pg_receivewal` starts from the server's *current*
  position, not the slot's `restart_lsn` (PG15 fixed this). The module therefore always keeps the newest shipped segment
  and the `.partial` in staging. Deleting the staging dir by hand creates a WAL gap. The restore planner now refuses
  targets past a gap, but nothing alerts on it yet; that belongs in a health check.
- **Timeline changes.** The planner follows the base's timeline only. A source that was itself promoted to a new
  timeline needs `.history`-aware chaining.
- **Single-worker only.** The streamer runs only where `moduleConfig.hasLock()` holds. A lock handover between Immich
  API workers was not exercised.
- **Not covered:** the Immich patch is not compiled or tested against Immich's suite, and the yucca proxy/michael path
  was not exercised (rest-server stood in for it). Large-DB base backup timing and restore throughput were not measured.

## Next steps

1. Decide on the pg_hba opt-in in base-images, and where the restore-time Postgres server comes from.
2. Add a WAL-aware retention step to the prune job, with tests, before anything ships.
3. Add WAL and DB-size telemetry (`pg_stat_wal`, staged bytes, last shipped LSN, slot `wal_status` and `safe_wal_size`)
   and surface a "PITR degraded" health state when the slot is lost or shipping lags.
4. Turn `restore.mjs` into an orchestrator job that feeds the existing maintenance rollback, then add a
   "restore to time" UI.
5. Later: generic Postgres WAL sources (user-provided conninfo plus slot, no setup step), and PG17 incremental base backups.
