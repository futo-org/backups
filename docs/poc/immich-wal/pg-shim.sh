#!/usr/bin/env bash
# Runs the Postgres client named by this symlink inside the Immich postgres image, so the orchestrator's WAL
# module can call version-matched binaries on a host that has none installed. restic runs --stdin-from-command with
# only PATH and HOME, so the settings come from a file next to the shim rather than the environment.
set -euo pipefail
source "$(dirname "$0")/pg-shim.env"

exec docker run --rm -i --init \
  --label futo-wal-e2e \
  --network host \
  --user "$(id -u):$(id -g)" \
  -v "$WAL_E2E_DIR:$WAL_E2E_DIR" \
  --entrypoint "$(basename "$0")" \
  "$PG_IMAGE" "$@"
