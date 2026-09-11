#!/usr/bin/env bash
# Restore the WireGuard volume from a backup tarball.
# Usage: scripts/restore.sh [--yes] <backup.tgz> [path-to-env-file]
#
# Order (docs/recovery.md): confirm -> detect original service state ->
# stop service -> take a CONSISTENT safety backup of the current volume ->
# clear volume -> extract archive -> start service only if it was running
# before -> health verification. A pre-restore safety copy taken while the
# service is stopped is itself transaction-consistent, so it is always the
# fallback recovery source; a failed extraction never destroys it.
#
# The original service state is preserved: a restore never leaves a
# previously-stopped service running, and never leaves a previously-running
# service stopped.
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Consumer-owned default (lib.sh deliberately does not define it).
EDGE_BACKUP_DIR="${EDGE_BACKUP_DIR:-${EDGE_ROOT}/backups}"

if [[ "${1:-}" == "--yes" ]]; then
  CONFIRMED=1
  shift
else
  CONFIRMED=0
fi

if [[ $# -lt 1 ]]; then
  printf 'Usage: scripts/restore.sh [--yes] <backup.tgz> [path-to-env-file]\n' >&2
  exit 1
fi

BACKUP_FILE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -f "${BACKUP_FILE}" ]] || edge_fail "backup file not found: ${BACKUP_FILE}"
# Resolve once at top level: edge_compose reads the exported EDGE_ENV_FILE.
EDGE_ENV_FILE="$(edge_resolve_env "${2:-}")" || exit 1
export EDGE_ENV_FILE
edge_require_docker || exit 1

volume="$(edge_require_volume)" || exit 1

printf 'This will OVERWRITE volume "%s" with %s.\n' "${volume}" "${BACKUP_FILE}"
printf 'The service will be stopped during the restore.\n'
if [[ "${CONFIRMED}" -ne 1 ]]; then
  read -r -p 'Type YES to continue: ' answer
  [[ "${answer}" == "YES" ]] || edge_fail "aborted (expected 'YES')"
fi

# Detect the original service state BEFORE stopping anything.
was_running=0
if edge_wg_running; then
  was_running=1
fi

edge_info "Stopping wg-easy (state before restore: $([[ ${was_running} -eq 1 ]] && echo running || echo stopped))"
edge_compose stop wg-easy >&2 || edge_compose down >/dev/null 2>&1 || true

# Consistent safety backup of the CURRENT volume, taken while the service is
# stopped. This is the only known-good fallback if extraction fails.
ts="$(date -u +%Y%m%dT%H%M%SZ)"
safety="${EDGE_BACKUP_DIR}/wg-pre-restore-${ts}.tgz"
mkdir -p "${EDGE_BACKUP_DIR}"
edge_info "Safety backup (stopped-state, consistent): ${safety}"
if ! edge_tar_volume "${volume}" "${safety}"; then
  edge_fail "pre-restore safety backup FAILED; aborting to protect current state (run: bash scripts/backup.sh ${EDGE_ENV_FILE})"
fi
if [[ ! -s "${safety}" ]]; then
  edge_fail "pre-restore safety backup is EMPTY; aborting (volume may be broken; do not restore over an unknown state)"
fi

edge_info "Clearing volume ${volume}"
# Remove normal files, single-dot hidden files, and double-dot-prefixed hidden
# files (for example `..state`). The previous two-pattern form could leave the
# latter behind and mix old state into the restored snapshot.
docker run --rm -v "${volume}:/data" alpine:3.20 sh -c \
  'rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null || true'

edge_info "Extracting ${BACKUP_FILE}"
if ! docker run --rm \
  -v "${volume}:/data" \
  -v "$(edge_native "$(dirname "${BACKUP_FILE}")"):/backup:ro" \
  alpine:3.20 \
  tar xzf "/backup/$(basename "${BACKUP_FILE}")" -C /data; then
  printf 'ERROR: restore extraction failed.\n' >&2
  printf 'Recovery: the consistent safety copy was NOT modified and is still at:\n  %s\n' "${safety}" >&2
  printf 'Restore from it with: bash scripts/restore.sh --yes %s %s\n' "${safety}" "${EDGE_ENV_FILE}" >&2
  edge_fail "extraction failed; no automatic retry loop was started"
fi

# Preserve the original service state.
if [[ "${was_running}" -eq 1 ]]; then
  edge_info "Restarting stack"
  edge_compose up -d >&2
  edge_wait_healthy "${EDGE_HEALTH_TIMEOUT_S:-180}" >&2 || edge_fail "restore ok but wg-easy not healthy after start; inspect: bash scripts/status.sh ${EDGE_ENV_FILE}"
  bash "${SCRIPT_DIR}/healthcheck.sh" "${EDGE_ENV_FILE}" >&2
  edge_info "Restore complete. Verify clients, then run scripts/status.sh"
else
  edge_info "Service was stopped before restore; leaving it stopped. Start with: bash scripts/deploy.sh ${EDGE_ENV_FILE}"
fi
