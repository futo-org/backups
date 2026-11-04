#!/usr/bin/env bash
# End-to-end PoC of continuous WAL archiving for Immich: run from the repo root with
#   mise //packages/yucca-sdk/orchestration-api:build && mise exec -- docs/poc/immich-wal/e2e.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
PREFIX=futo-wal-e2e
export PG_IMAGE=${PG_IMAGE:-ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23}
REST_IMAGE=${REST_IMAGE:-restic/rest-server:0.14.0}
export PG_PORT=${PG_PORT:-55432}
REST_PORT=${REST_PORT:-58000}
ROWS=${ROWS:-2000}
export PG_PASSWORD=e2e-$RANDOM$RANDOM
export RESTIC_KEY_HEX=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
export RESTIC_PASSWORD=$RESTIC_KEY_HEX
export RESTIC_REPOSITORY=rest:http://127.0.0.1:$REST_PORT/immich
export MAX_SLOT_WAL_KEEP_SIZE=${MAX_SLOT_WAL_KEEP_SIZE:-64MB}
export SHIP_INTERVAL_MS=${SHIP_INTERVAL_MS:-5000}
export WAL_E2E_DIR=$(mktemp -d "${TMPDIR:-/tmp}/$PREFIX.XXXXXX")
export WAL_RESTORE_TMPDIR=$WAL_E2E_DIR
export PG_BIN_DIR=$WAL_E2E_DIR/bin
export LIBRARY_DIR=$WAL_E2E_DIR/library
DRIVER_LOG=$WAL_E2E_DIR/driver.log
DRIVER_PID=

step() { printf '\n== %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local status=$?
  if [[ -n $DRIVER_PID ]] && kill -0 "$DRIVER_PID" 2>/dev/null; then
    kill "$DRIVER_PID" 2>/dev/null || true
  fi
  if [[ $status -ne 0 && -f $DRIVER_LOG ]]; then
    echo '-- driver log (tail)' >&2
    tail -n 40 "$DRIVER_LOG" >&2
  fi
  docker ps -aq --filter "label=$PREFIX" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  rm -rf "$WAL_E2E_DIR"
  exit "$status"
}
trap cleanup EXIT

sql() { docker exec -i "$PREFIX-pg" psql -X -q -A -t -U postgres -v ON_ERROR_STOP=1 "$@"; }
immich() { sql -d immich "$@"; }

[[ -f $ROOT/packages/yucca-sdk/orchestration-api/dist/services/immichWal.service.js ]] ||
  fail 'build the orchestrator first: mise //packages/yucca-sdk/orchestration-api:build'
command -v restic >/dev/null || fail 'restic must be on PATH (run through mise exec)'

mkdir -p "$PG_BIN_DIR" "$LIBRARY_DIR"
cp "$HERE/pg-shim.sh" "$PG_BIN_DIR/pg-shim"
printf 'WAL_E2E_DIR=%q\nPG_IMAGE=%q\n' "$WAL_E2E_DIR" "$PG_IMAGE" >"$PG_BIN_DIR/pg-shim.env"
for bin in psql pg_receivewal pg_basebackup; do ln -s pg-shim "$PG_BIN_DIR/$bin"; done
echo 'library placeholder' >"$LIBRARY_DIR/photo.jpg"

step 'Start rest-server (stand-in for michael) and the Immich postgres image'
docker run -d --name "$PREFIX-rest" --label "$PREFIX" -e DISABLE_AUTHENTICATION=1 \
  -p "127.0.0.1:$REST_PORT:8000" "$REST_IMAGE" >/dev/null
docker run -d --name "$PREFIX-pg" --label "$PREFIX" --shm-size 128m \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" -e POSTGRES_USER=postgres -e POSTGRES_DB=immich \
  -e POSTGRES_INITDB_ARGS=--data-checksums \
  -p "127.0.0.1:$PG_PORT:5432" "$PG_IMAGE" >/dev/null
for _ in $(seq 60); do
  if docker logs "$PREFIX-pg" 2>&1 | grep -q 'PostgreSQL init process complete' && immich -c 'SELECT 1' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
immich -c 'SELECT version()'
restic init >/dev/null
echo "restic repository initialised at $RESTIC_REPOSITORY"

step 'Create an Immich-like schema (asset + vchord smart_search)'
immich <<'SQL'
CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
CREATE TABLE asset (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "ownerId" uuid NOT NULL,
  "originalPath" text NOT NULL,
  "fileCreatedAt" timestamptz NOT NULL DEFAULT now(),
  checksum bytea NOT NULL,
  batch text NOT NULL
);
CREATE INDEX asset_owner_idx ON asset ("ownerId", "fileCreatedAt");
CREATE TABLE smart_search ("assetId" uuid PRIMARY KEY REFERENCES asset (id) ON DELETE CASCADE, embedding vector(512) NOT NULL);
SQL

step 'Replication is rejected by the stock pg_hba.conf'
if "$PG_BIN_DIR/pg_basebackup" -d "host=127.0.0.1 port=$PG_PORT user=postgres password=$PG_PASSWORD" \
  -D - -Ft -X none >/dev/null 2>"$WAL_E2E_DIR/hba.err"; then
  fail 'replication unexpectedly allowed before the pg_hba opt-in'
fi
grep -o 'no pg_hba.conf entry for replication connection[^,]*' "$WAL_E2E_DIR/hba.err" | head -n1

step 'Opt in: append a replication line and reload (what DB_ALLOW_REPLICATION would do in base-images)'
docker exec "$PREFIX-pg" bash -c 'echo "host replication postgres all scram-sha-256" >>"$PGDATA/pg_hba.conf"'
immich -c 'SELECT pg_reload_conf()' >/dev/null
immich -c "SELECT line_number, type, database, user_name, address, auth_method FROM pg_hba_file_rules WHERE 'replication' = ANY(database) AND address = 'all'"

step 'Start the orchestrator WAL module (driver around ImmichWalService)'
coproc DRIVER { exec node "$HERE/driver.mjs" 2>>"$DRIVER_LOG"; }
driver() {
  echo "$1" >&"${DRIVER[1]}"
  local line
  while IFS= read -r line <&"${DRIVER[0]}"; do
    if [[ $line == '@@ '* ]]; then
      line=${line#@@ }
      if jq -e 'has("error")' <<<"$line" >/dev/null; then
        fail "driver $1: $(jq -r .error <<<"$line")"
      fi
      echo "$line"
      return
    fi
    echo "$line" >>"$DRIVER_LOG"
  done
  fail "driver exited during '$1'"
}
driver tick >/dev/null
immich -c "SELECT slot_name, slot_type, active, wal_status FROM pg_replication_slots"
immich -c 'SHOW max_slot_wal_keep_size'

step 'Base backup through restic --stdin-from-command'
BASE=$(driver base)
echo "base: $BASE"

insert_rows() {
  immich <<SQL
INSERT INTO asset ("ownerId", "originalPath", checksum, batch)
SELECT gen_random_uuid(), '/data/library/$1/' || g || '.jpg', sha256(('$1' || g)::bytea), '$1' FROM generate_series(1, $ROWS) g;
INSERT INTO smart_search ("assetId", embedding)
SELECT id, (SELECT array_agg(random())::real[] FROM generate_series(1, 512) WHERE a.id IS NOT NULL)::vector FROM asset a WHERE batch = '$1';
SQL
}

WAL_START=$(immich -c 'SELECT pg_current_wal_lsn()')

step "Write rows A ($ROWS assets + embeddings)"
insert_rows A

step 'Library snapshot: restore point, WAL switch, wait until shipped, then the file walk tagged with the LSN'
SNAPSHOT=$(driver snapshot)
LSN1=$(jq -r .lsn <<<"$SNAPSHOT")
SNAP1=$(jq -r .snapshotId <<<"$SNAPSHOT")
echo "LSN1=$LSN1 library snapshot=$SNAP1"
restic snapshots --no-lock "$SNAP1" --json | jq -r '.[0].tags[]'
sleep 2
T1=$(immich -c "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')")
sleep 2

step "Write rows B ($ROWS assets + embeddings), after LSN1 and T1=$T1"
insert_rows B
WAL_END=$(immich -c 'SELECT pg_current_wal_lsn()')
for _ in $(seq 30); do
  [[ $(immich -c "SELECT flush_lsn >= '$WAL_END' FROM pg_stat_replication WHERE application_name = 'pg_receivewal'") == t ]] && break
  sleep 1
done
driver tick >/dev/null
echo 'B streamed and shipped as a .partial segment'

step 'WAL volume'
WAL_BYTES=$(immich -c "SELECT pg_wal_lsn_diff('$WAL_END', '$WAL_START')")
echo "workload WAL: $WAL_BYTES bytes ($(numfmt --to=iec "$WAL_BYTES")) for 2x$ROWS assets + 512-d embeddings"
restic snapshots --no-lock --json | jq -r '
  def kind: if (.tags // []) | index("immich-wal") then "immich-wal" elif (.tags // []) | index("immich-base") then "immich-base" else "library" end;
  group_by(kind)[] | "\(.[0] | kind): \(length) snapshot(s), \([.[].summary.total_bytes_processed // 0] | add) bytes read, \([.[].summary.data_added_packed // 0] | add) bytes added to the repo"'
echo "staged files left: $(ls "$WAL_E2E_DIR/staging/receive" | tr '\n' ' ')"

restore_into() {
  local database=$1
  shift
  immich -c "CREATE DATABASE $database" >/dev/null
  node "$HERE/restore.mjs" "$@" --load-cmd "docker exec -i $PREFIX-pg psql -X -q -U postgres -d $database -v ON_ERROR_STOP=1 >/dev/null"
}
count() { sql -d "$1" -c "SELECT count(*) FILTER (WHERE batch = 'A') || ' ' || count(*) FILTER (WHERE batch = 'B') || ' ' || (SELECT count(*) FROM smart_search) FROM asset"; }
expect_counts() {
  local database=$1 a=$2 b=$3
  read -r got_a got_b got_search <<<"$(count "$database")"
  echo "$database: A=$got_a B=$got_b smart_search=$got_search"
  [[ $got_a == "$a" && $got_b == "$b" && $got_search == $((a + b)) ]] || fail "$database expected A=$a B=$b"
}

step "Restore to the library snapshot (LSN1=$LSN1) in a scratch Postgres, pg_dump into restored_lsn1"
restore_into restored_lsn1 --snapshot "$SNAP1"
expect_counts restored_lsn1 "$ROWS" 0

step "Restore to the timestamp T1=$T1"
restore_into restored_time --time "$T1"
expect_counts restored_time "$ROWS" 0

step 'Restore to the latest archived WAL'
restore_into restored_latest --latest
expect_counts restored_latest "$ROWS" "$ROWS"

step "Slot cap: stop the streamer and write well past max_slot_wal_keep_size=$MAX_SLOT_WAL_KEEP_SIZE"
driver stop >/dev/null
wait "$DRIVER_PID" 2>/dev/null || true
DRIVER_PID=
for _ in $(seq 30); do
  [[ $(immich -c 'SELECT active FROM pg_replication_slots') == f ]] && break
  sleep 1
done
immich -c "SELECT 'before: active=' || active || ' wal_status=' || wal_status FROM pg_replication_slots"
WAL_STOPPED=$(immich -c 'SELECT pg_current_wal_lsn()')
immich <<'SQL'
CREATE TABLE churn AS SELECT g AS id, repeat(md5(g::text), 20) AS payload FROM generate_series(1, 250000) g;
CHECKPOINT;
SQL
immich -c "SELECT 'after:  active=' || active || ' wal_status=' || wal_status || ' restart_lsn=' || coalesce(restart_lsn::text, 'NULL') || ' WAL written since stop=' || pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), '$WAL_STOPPED')) FROM pg_replication_slots"
immich -c "SELECT 'pg_wal: ' || count(*) || ' files, ' || pg_size_pretty(sum(size)) FROM pg_ls_waldir()"
[[ $(immich -c "SELECT wal_status FROM pg_replication_slots") == lost ]] || fail 'expected the capped slot to be lost'

step 'Restarting the module recreates the lost slot and forces a new base backup'
coproc DRIVER { exec node "$HERE/driver.mjs" 2>>"$DRIVER_LOG"; }
driver 'base-if-due'
sed 's/\x1b\[[0-9;]*m//g' "$DRIVER_LOG" | grep -o 'Replication slot .*' | head -n1 || true
immich -c "SELECT 'slot: active=' || active || ' wal_status=' || wal_status FROM pg_replication_slots"
driver stop >/dev/null

step 'PASS'
