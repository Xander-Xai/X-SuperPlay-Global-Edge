#!/usr/bin/env bash
# Deploy the X-SuperPlay Global Edge stack.
# Usage: scripts/deploy.sh [path-to-env-file]
# Local/CI: validate -> compose up -d -> wait healthy -> healthcheck.
# Production: mandatory preflight (which includes validate) -> compose up -d
#             -> wait healthy -> healthcheck -> data-plane stabilization when
#             onboarding already created the WireGuard interface.
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

EDGE_ENV_FILE="$(edge_resolve_env "${1:-}")" || exit 1
export EDGE_ENV_FILE
edge_require_docker || exit 1

edge_env="$(grep -E '^EDGE_ENV=' "${EDGE_ENV_FILE}" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
edge_env="${edge_env:-local}"

if [[ "${edge_env}" == "production" ]]; then
  edge_info "Running mandatory production preflight (${EDGE_ENV_FILE})"
  "${SCRIPT_DIR}/preflight.sh" "${EDGE_ENV_FILE}"
else
  edge_info "Validating configuration (${EDGE_ENV_FILE})"
  "${SCRIPT_DIR}/validate.sh" "${EDGE_ENV_FILE}"
fi

edge_info "Starting stack"
edge_compose up -d

edge_info "Waiting for wg-easy to become healthy"
edge_wait_healthy "${EDGE_HEALTH_TIMEOUT_S:-180}"

edge_info "Running healthcheck"
bash "${SCRIPT_DIR}/healthcheck.sh" "${EDGE_ENV_FILE}"

# After onboarding, enforce the MTU/MSS policy on every supported redeploy.
# A fresh install legitimately has no wg interface yet; that state is not a
# deployment failure, but the operator must re-run deploy.sh or explicitly run
# data-plane-tune.sh --apply immediately after onboarding and before P8.
edge_info "Applying data-plane stabilization when WireGuard is configured"
tune_log="$(mktemp)"
tune_rc=0
bash "${SCRIPT_DIR}/data-plane-tune.sh" --apply "${EDGE_ENV_FILE}" >"${tune_log}" 2>&1 || tune_rc=$?
cat "${tune_log}"
rm -f "${tune_log}"
case "${tune_rc}" in
  0) edge_info "Data-plane stabilization applied" ;;
  2) edge_info "WireGuard not configured yet; run data-plane-tune.sh --apply after onboarding" ;;
  *) printf 'ERROR: data-plane stabilization failed (rc=%s)\n' "${tune_rc}" >&2; exit "${tune_rc}" ;;
esac

edge_info "Deploy complete. Inspect with: bash scripts/status.sh"
