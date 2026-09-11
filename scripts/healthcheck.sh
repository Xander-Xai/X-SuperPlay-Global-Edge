#!/usr/bin/env bash
# L1 CONTROL-PLANE healthcheck for the X-SuperPlay Global Edge stack.
# Scope (docs/acceptance.md): docker daemon reachable + wg-easy container
# running + container health healthy + admin UI reachable over loopback.
# This is NOT a WireGuard data-plane check: before onboarding there may be
# no wg0 interface, which is expected, not a failure. Post-onboarding
# WireGuard readiness is verified by scripts/wireguard-check.sh (L2) and
# scripts/p8-check.sh.
# Usage: scripts/healthcheck.sh [path-to-env-file]
# Exit 0 = healthy, 1 = unhealthy. Machine-readable; intended for cron/CI.
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Resolve once at top level: edge_compose reads the exported EDGE_ENV_FILE.
EDGE_ENV_FILE="$(edge_resolve_env "${1:-}")" || exit 1
export EDGE_ENV_FILE
edge_require_docker || exit 1

cid="$(edge_compose ps -q wg-easy 2>/dev/null | head -n1)"
if [[ -z "${cid}" ]]; then
  printf 'UNHEALTHY: wg-easy container is not running\n' >&2
  exit 1
fi

state="$(docker inspect -f '{{.State.Status}}' "${cid}")"
if [[ "${state}" != "running" ]]; then
  printf 'UNHEALTHY: container state = %s\n' "${state}" >&2
  exit 1
fi

health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}")"
if [[ "${health}" != "healthy" ]]; then
  printf 'UNHEALTHY: container health = %s\n' "${health}" >&2
  exit 1
fi

# Loopback UI probe from inside the container (curl may be absent on host).
if ! docker exec "${cid}" node -e \
  "fetch('http://127.0.0.1:51821/').then(r=>process.exit(r.status<500?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
  printf 'UNHEALTHY: admin UI probe failed\n' >&2
  exit 1
fi

printf 'HEALTHY: wg-easy running, health=%s, UI probe ok\n' "${health}"
