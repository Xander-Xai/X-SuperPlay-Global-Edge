#!/usr/bin/env bash
# Status report for the X-SuperPlay Global Edge stack.
# Usage: scripts/status.sh [path-to-env-file]
# Read-only; never fails on informational gaps (e.g. no tunnel configured yet).
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Resolve once at top level: edge_compose reads the exported EDGE_ENV_FILE.
EDGE_ENV_FILE="$(edge_resolve_env "${1:-}")" || exit 1
export EDGE_ENV_FILE
edge_require_docker || exit 1

edge_info "Project: $(edge_project_name 2>/dev/null || echo unknown)"
edge_info "Env file: ${EDGE_ENV_FILE}"

printf '\n=== Compose services ===\n'
edge_compose ps || true

cid="$(edge_compose ps -q wg-easy 2>/dev/null | head -n1)"
if [[ -n "${cid}" ]]; then
  printf '\n=== Container health ===\n'
  docker inspect -f 'state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restarts={{.RestartCount}}' "${cid}" || true
fi

printf '\n=== WireGuard interface (inside container) ===\n'
if [[ -n "${cid}" ]] && docker exec "${cid}" wg show 2>/dev/null; then
  :
else
  printf '(no WireGuard interface yet; expected before first interactive setup)\n'
fi

printf '\n=== Persistent volume ===\n'
volume="$(edge_wg_volume 2>/dev/null || true)"
if [[ -n "${volume}" ]]; then
  docker run --rm -v "${volume}:/data" alpine:3.20 du -sh /data 2>/dev/null || printf 'volume %s exists (size probe unavailable)\n' "${volume}"
else
  printf '(no volume yet; deploy the stack first)\n'
fi

printf '\n=== Recent logs ===\n'
if [[ -n "${cid}" ]]; then
  docker logs --tail 15 "${cid}" 2>&1 || true
fi

printf '\n'
edge_info "Status gathered. Full diagnostics: docker compose -f ${EDGE_COMPOSE_FILE} logs -f wg-easy"
