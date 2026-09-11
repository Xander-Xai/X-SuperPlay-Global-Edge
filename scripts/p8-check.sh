#!/usr/bin/env bash
# P8 post-onboarding functional gate (host-visible checks).
# Usage: bash scripts/p8-check.sh [path-to-env-file]
#
# Host-side P8 is deliberately strict: control plane + WireGuard handshake are
# not enough. The configured interface must also match the repository MTU policy
# and have bidirectional TCP MSS clamping present. Real-payload client acceptance
# remains a separate Windows/Android L3 responsibility.
#
# STDOUT contract:
#   human-readable per-check lines ([PASS]/[FAIL]/[INFO]), a summary line
#   (passes=... fails=... infos=...), and the final machine line
#   RESULT=PASS|READY_NO_HANDSHAKE|FAIL.
# Exit: 0 = PASS or READY_NO_HANDSHAKE; 1 = FAIL / environment error.
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

EDGE_ENV_FILE="$(edge_resolve_env "${1:-}")" || exit 1
export EDGE_ENV_FILE
edge_require_docker || { printf 'RESULT=FAIL\n'; printf 'ERROR: docker daemon not reachable\n' >&2; exit 1; }

fails=0
warned=0
passes=0

report() {
  local label="$1" status="$2"
  shift 2
  case "${status}" in
    PASS)
      printf '[PASS] %s\n' "${label}"
      for line in "$@"; do [[ -n "${line}" ]] && printf '       %s\n' "${line}"; done
      passes=$((passes + 1))
      ;;
    FAIL)
      printf '[FAIL] %s\n' "${label}"
      for line in "$@"; do printf '       %s\n' "${line}"; done
      fails=$((fails + 1))
      ;;
    INFO)
      printf '[INFO] %s\n' "${label}"
      for line in "$@"; do printf '       %s\n' "${line}"; done
      warned=$((warned + 1))
      ;;
  esac
}

cid="$(edge_compose ps -q wg-easy 2>/dev/null | head -n1)"
if [[ -z "${cid}" ]]; then
  report "wg-easy container running" FAIL "container not present; run bash scripts/deploy.sh ${EDGE_ENV_FILE}"
  printf 'RESULT=FAIL\n'
  exit 1
fi
report "wg-easy container running" PASS

state="$(docker inspect -f '{{.State.Status}}' "${cid}")"
if [[ "${state}" == "running" ]]; then
  report "container state = running" PASS
else
  report "container state = running" FAIL "state=${state}"
fi

health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}")"
if [[ "${health}" == "healthy" ]]; then
  report "container health = healthy" PASS
else
  report "container health = healthy" FAIL "health=${health}"
fi

if docker exec "${cid}" node -e \
  "fetch('http://127.0.0.1:51821/').then(r=>process.exit(r.status<500?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
  report "admin UI reachable (loopback probe)" PASS
else
  report "admin UI reachable (loopback probe)" FAIL "HTTP probe inside container failed"
fi

restarts="$(docker inspect -f '{{.RestartCount}}' "${cid}" 2>/dev/null | tr -d '[:space:]')"
report "container restart count" INFO "restarts=${restarts:-unknown}"

volume="$(edge_wg_volume 2>/dev/null || true)"
if [[ -n "${volume}" ]]; then
  report "persistent volume present" PASS "volume=${volume}"
else
  report "persistent volume present" FAIL "no project volume found; deploy first"
fi

wg_state=""
wg_detail=""
if wg_out="$(bash "${SCRIPT_DIR}/wireguard-check.sh" "${EDGE_ENV_FILE}" 2>/dev/null)"; then
  wg_rc=0
else
  wg_rc=$?
fi
if [[ -n "${wg_out:-}" ]]; then
  wg_state="$(printf '%s\n' "${wg_out}" | sed -n 's/^STATE=//p' | head -n1)"
  wg_detail="${wg_out}"
fi

case "${wg_state}" in
  HANDSHAKE_OK|READY_NO_HANDSHAKE)
    report "WireGuard interface + consistent port (L2)" PASS
    ;;
  NOT_CONFIGURED)
    report "WireGuard interface exists (onboarding)" FAIL "no wg interface yet; complete wg-easy setup, then re-run"
    ;;
  MISMATCH)
    report "WireGuard listen port == EDGE_WIREGUARD_PORT" FAIL "actual wg listen port differs from expected; fix via admin UI"
    ;;
  *)
    report "WireGuard data plane probe" FAIL "wireguard-check.sh returned state '${wg_state:-unknown}' (rc=${wg_rc})"
    ;;
esac

peers="$(printf '%s\n' "${wg_detail}" | sed -n 's/^peers=//p' | head -n1)"
peers="${peers:-0}"
if [[ "${peers}" =~ ^[0-9]+$ ]] && (( peers >= 1 )); then
  report "at least one peer configured" PASS "peers=${peers}"
elif [[ "${wg_state}" == "NOT_CONFIGURED" || "${wg_state}" == "MISMATCH" ]]; then
  report "at least one peer configured" INFO "peers=${peers} (state=${wg_state})"
else
  report "at least one peer configured" FAIL "peers=${peers}; create a client in the admin UI and re-run"
fi

handshake="$(printf '%s\n' "${wg_detail}" | sed -n 's/^handshake=//p' | head -n1)"
handshake_fresh="$(printf '%s\n' "${wg_detail}" | sed -n 's/^handshake_fresh=//p' | head -n1)"
handshake_age="$(printf '%s\n' "${wg_detail}" | sed -n 's/^handshake_age_seconds=//p' | head -n1)"
handshake_max_age="$(printf '%s\n' "${wg_detail}" | sed -n 's/^handshake_max_age_seconds=//p' | head -n1)"

if [[ "${handshake_fresh}" == "yes" ]]; then
  report "recent handshake visible (current real-client evidence)" PASS \
    "age=${handshake_age}s max=${handshake_max_age}s"
elif [[ "${handshake}" == "yes" ]]; then
  report "recent handshake visible (current real-client evidence)" INFO \
    "historical handshake exists but is stale: age=${handshake_age:-unknown}s max=${handshake_max_age:-unknown}s"
else
  report "recent handshake visible (current real-client evidence)" INFO \
    "no handshake yet; connect the real client and generate traffic before re-running"
fi

# P8 hard gate: server-side MTU and MSS policy must be present. This catches
# the incident class where handshake/egress look healthy while large TLS flows
# stall because of PMTU/MSS behavior.
tune_out=""
tune_rc=0
if tune_out="$(bash "${SCRIPT_DIR}/data-plane-tune.sh" --check "${EDGE_ENV_FILE}" 2>/dev/null)"; then
  tune_rc=0
else
  tune_rc=$?
fi
if [[ "${tune_rc}" -eq 0 ]]; then
  actual_mtu="$(printf '%s\n' "${tune_out}" | sed -n 's/^actual_mtu=//p' | head -n1)"
  report "WireGuard MTU + bidirectional TCP MSS policy" PASS "actual_mtu=${actual_mtu}"
else
  tune_state="$(printf '%s\n' "${tune_out}" | sed -n 's/^STATE=//p' | head -n1)"
  report "WireGuard MTU + bidirectional TCP MSS policy" FAIL \
    "state=${tune_state:-unknown} rc=${tune_rc}" \
    "run: bash scripts/data-plane-tune.sh --apply ${EDGE_ENV_FILE}"
fi

printf '\n'
printf 'passes=%s fails=%s infos=%s\n' "${passes}" "${fails}" "${warned}"
if (( fails > 0 )); then
  printf 'RESULT=FAIL\n'
  exit 1
fi
if [[ "${handshake_fresh}" == "yes" ]]; then
  printf 'RESULT=PASS\n'
else
  printf 'RESULT=READY_NO_HANDSHAKE\n'
fi
exit 0
