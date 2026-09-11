#!/usr/bin/env bash
# Backup the persistent WireGuard volume to ./backups (or $EDGE_BACKUP_DIR).
# Usage: scripts/backup.sh [path-to-env-file] [output-dir]
#
# Consistency (docs/recovery.md): wg-easy v15 stores state (SQLite + config)
# in the volume. A tarball taken while the service is writing is not a strong
# consistency guarantee, so for G1 this script uses a brief maintenance stop:
#
#   service running -> stop wg-easy -> archive volume -> start wg-easy
#                      -> wait healthy   (state preserved)
#   service stopped  -> archive volume only (never started by a backup)
#
# On failure the original service state is restored as a best effort.
# STDOUT contract: prints exactly one line — the artifact path — so callers
# can capture it: backup="$(scripts/backup.sh ...)". Progress goes to stderr.
# The tarball contains wg-easy state (private keys) — store it encrypted and
# NEVER commit it. It is ignored via .gitignore (backups/).
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Consumer-owned default (lib.sh deliberately does not define it).
EDGE_BACKUP_DIR="${EDGE_BACKUP_DIR:-${EDGE_ROOT}/backups}"

# Resolve once at top level: edge_compose reads the exported EDGE_ENV_FILE.
EDGE_ENV_FILE="$(edge_resolve_env "${1:-}")" || exit 1
export EDGE_ENV_FILE
edge_require_docker || exit 1

OUT_DIR="${2:-${EDGE_BACKUP_DIR}}"
mkdir -p "${OUT_DIR}"
# Docker bind mounts require an absolute host path (relative sources are
# mis-parsed as named volumes), so normalize before mounting.
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

volume="$(edge_require_volume)" || exit 1
ts="$(date -u +%Y%m%dT%H%M%SZ)"
project="$(edge_project_name)"
out_file="${OUT_DIR}/wg-${project}-${ts}.tgz"

# Preserve the original service state across the brief maintenance stop.
was_running=0
if edge_wg_running; then
  was_running=1
  edge_info "Stopping wg-easy for a consistent volume snapshot" >&2
  edge_compose stop wg-easy >&2 || edge_fail "failed to stop wg-easy for backup"
fi

# Best-effort state restoration on any exit while we stopped the service.
restore_on_exit() {
  local rc=$?
  if [[ "${was_running}" -eq 1 ]] && edge_compose ps -q wg-easy 2>/dev/null | grep -q .; then
    : # already running again
  elif [[ "${was_running}" -eq 1 ]]; then
    edge_warn "Restoring wg-easy to running state after backup" >&2
    edge_compose start wg-easy >/dev/null 2>&1 || true
    edge_wait_healthy "${EDGE_HEALTH_TIMEOUT_S:-120}" >/dev/null 2>&1 || true
  fi
  exit "${rc}"
}
trap restore_on_exit EXIT

edge_info "Backing up volume '${volume}' -> ${out_file}" >&2
if ! edge_tar_volume "${volume}" "${out_file}"; then
  edge_fail "backup failed; service state was restored"
fi

if [[ "${was_running}" -eq 1 ]]; then
  edge_info "Restarting wg-easy" >&2
  edge_compose start wg-easy >&2 || edge_fail "backup ok but failed to restart wg-easy; run scripts/deploy.sh"
  edge_wait_healthy "${EDGE_HEALTH_TIMEOUT_S:-180}" >&2 || edge_fail "backup ok but wg-easy not healthy after restart"
else
  edge_info "Service was stopped; leaving it stopped" >&2
fi

# Volume snapshot happened while stopped: restore flag cleared so the EXIT
# trap does not double-restart.
was_running=0

size="$(du -h "${out_file}" | cut -f1)"
edge_info "Backup complete: ${out_file} (${size})" >&2
printf '%s\n' "${out_file}"
