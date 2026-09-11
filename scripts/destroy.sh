#!/usr/bin/env bash
# Destroy the X-SuperPlay Global Edge stack.
# Usage: scripts/destroy.sh [--yes] [--volumes] [path-to-env-file]
#   --yes      required: skip interactive confirmation
#   --volumes  also delete the persistent WireGuard volume (data loss!)
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIRMED=0
DROP_VOLUMES=0
POSITIONAL=()

for arg in "$@"; do
  case "${arg}" in
    --yes) CONFIRMED=1 ;;
    --volumes) DROP_VOLUMES=1 ;;
    *) POSITIONAL+=("${arg}") ;;
  esac
done

# Resolve once at top level: edge_compose reads the exported EDGE_ENV_FILE.
EDGE_ENV_FILE="$(edge_resolve_env "${POSITIONAL[0]:-}")" || exit 1
export EDGE_ENV_FILE
edge_require_docker || exit 1

printf 'This will stop and remove the stack containers and networks.\n'
if [[ "${DROP_VOLUMES}" -eq 1 ]]; then
  printf 'WARNING: --volumes is set: the persistent WireGuard volume will be DELETED.\n'
  printf 'All client configurations and keys will be lost unless you have a backup.\n'
fi
if [[ "${CONFIRMED}" -ne 1 ]]; then
  read -r -p 'Type YES to continue: ' answer
  [[ "${answer}" == "YES" ]] || edge_fail "aborted (expected 'YES')"
fi

if [[ "${DROP_VOLUMES}" -eq 1 ]]; then
  printf 'Take a last backup? Recommend: bash scripts/backup.sh %s\n' "${EDGE_ENV_FILE}"
  edge_compose down -v
else
  edge_compose down
fi

edge_info "Destroy complete."
if [[ "${DROP_VOLUMES}" -eq 1 ]]; then
  edge_warn "Volume removed. Rebuild: bash scripts/deploy.sh ${EDGE_ENV_FILE}"
else
  edge_info "Volume kept. Redeploy: bash scripts/deploy.sh ${EDGE_ENV_FILE}"
fi
