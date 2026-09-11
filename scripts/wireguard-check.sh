#!/usr/bin/env bash
# L2 WIREGUARD DATA-PLANE check for the X-SuperPlay Global Edge stack.
# Usage:
#   bash scripts/wireguard-check.sh [env-file]                # any state is OK
#   bash scripts/wireguard-check.sh --require-configured [env-file]
#
# Purpose (docs/acceptance.md): after onboarding this proves whether the
# WireGuard interface exists, listens on the expected UDP port, has peers,
# and has a RECENT handshake. It is deliberately separate from
# scripts/healthcheck.sh (L1 control plane: container + admin UI alive).
#
# Distinction this script enforces:
#   - BEFORE onboarding: wg0 absent is NOT a broken container -> NOT_CONFIGURED
#   - AFTER  onboarding: wg0 absent IS a failure (--require-configured)
#   - A historical/stale handshake is NOT current P8 evidence ->
#     READY_NO_HANDSHAKE with handshake_fresh=no
#
# Expected listen port (EDGE_WIREGUARD_PORT from the env file) is compared
# against the actual `wg show <iface> listen-port`. A mismatch is reported
# loudly (MISMATCH); the script never silently rewrites persistent state.
#
# STDOUT machine contract (one KEY=VALUE per line, STATE ALWAYS first):
#   STATE=NOT_CONFIGURED|READY_NO_HANDSHAKE|HANDSHAKE_OK|MISMATCH|ERROR
#   interface=...
#   listen_port=...        (empty when no interface)
#   expected_port=...
#   peers=<count>
#   handshake=yes|no       (has ever handshaken)
#   handshake_fresh=yes|no
#   handshake_age_seconds=<integer|empty>
#   handshake_max_age_seconds=<integer>
# Diagnostics go to stderr.
#
# Exit codes:
#   0 = READY_NO_HANDSHAKE or HANDSHAKE_OK (data plane exists and is consistent)
#   1 = ERROR / MISMATCH / --require-configured with NOT_CONFIGURED
#   2 = NOT_CONFIGURED (informational; not a broken container)
#
# Test seam: when EDGE_WG_MOCK_BIN is set, `wg` invocations are replaced by
# that executable (arguments are passed through unchanged) instead of
# `docker exec <cid> wg`. scripts/self-test.sh uses this to exercise every
# state without a real WireGuard interface. This seam is test-only.
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

REQUIRE_CONFIGURED=0
ENV_ARG=""
for arg in "$@"; do
  case "${arg}" in
    --require-configured) REQUIRE_CONFIGURED=1 ;;
    -*) printf 'ERROR: unknown option: %s\n' "${arg}" >&2; exit 1 ;;
    *) ENV_ARG="${arg}" ;;
  esac
done

# Resolve once at top level: edge_compose reads the exported EDGE_ENV_FILE.
EDGE_ENV_FILE="$(edge_resolve_env "${ENV_ARG:-}")" || exit 1
export EDGE_ENV_FILE

get_env() {
  grep -E "^$1=" "${EDGE_ENV_FILE}" | tail -n1 | cut -d= -f2- | tr -d '\r' || true
}

# Expected WireGuard listen port, from the repository .env (metadata, not a
# wg-easy container variable). Defaults keep parity with .env.example.
expected_port="$(get_env EDGE_WIREGUARD_PORT)"
expected_port="${expected_port:-51820}"
[[ "${expected_port}" =~ ^[0-9]+$ ]] || edge_fail "EDGE_WIREGUARD_PORT in ${EDGE_ENV_FILE} is not an integer"

handshake_max_age="$(get_env EDGE_HANDSHAKE_MAX_AGE_S)"
handshake_max_age="${handshake_max_age:-300}"
[[ "${handshake_max_age}" =~ ^[0-9]+$ ]] || edge_fail "EDGE_HANDSHAKE_MAX_AGE_S in ${EDGE_ENV_FILE} is not an integer"
(( handshake_max_age >= 60 && handshake_max_age <= 3600 )) \
  || edge_fail "EDGE_HANDSHAKE_MAX_AGE_S must be between 60 and 3600 seconds"

emit() { # emit <KEY=VALUE>   (single pre-formatted argument)
  printf '%s\n' "$1"
}

state_error() { # state_error <message>
  emit "STATE=ERROR"
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

# Run `wg` against the container (or a mock binary in tests).
edge_wg_cmd() {
  if [[ -n "${EDGE_WG_MOCK_BIN:-}" ]]; then
    "${EDGE_WG_MOCK_BIN}" "$@"
    return
  fi
  edge_require_docker || return 1
  local cid
  cid="$(edge_compose ps -q wg-easy 2>/dev/null | head -n1)"
  [[ -n "${cid}" ]] || return 1
  docker exec "${cid}" wg "$@"
}

# --- L1 prerequisite: container must exist for a data-plane probe ------------
if [[ -z "${EDGE_WG_MOCK_BIN:-}" ]]; then
  edge_require_docker || state_error "docker daemon not reachable"
  cid="$(edge_compose ps -q wg-easy 2>/dev/null | head -n1)"
  if [[ -z "${cid}" ]]; then
    state_error "wg-easy container is not running (L1 healthcheck is authoritative for control plane)"
  fi
  if [[ "$(docker inspect -f '{{.State.Status}}' "${cid}" 2>/dev/null)" != "running" ]]; then
    state_error "wg-easy container is not in running state"
  fi
fi

# --- Interface presence -------------------------------------------------------
ifaces=""
if ! ifaces="$(edge_wg_cmd show interfaces 2>/dev/null)"; then
  state_error "wg show failed inside the container"
fi
iface="$(printf '%s\n' "${ifaces}" | head -n1 | tr -d '[:space:]')"

if [[ -z "${iface}" ]]; then
  emit "STATE=NOT_CONFIGURED"
  emit "interface="
  emit "listen_port="
  emit "expected_port=${expected_port}"
  emit "peers=0"
  emit "handshake=no"
  emit "handshake_fresh=no"
  emit "handshake_age_seconds="
  emit "handshake_max_age_seconds=${handshake_max_age}"
  if [[ "${REQUIRE_CONFIGURED}" -eq 1 ]]; then
    printf 'ERROR: no WireGuard interface found but onboarding is expected to be complete (--require-configured).\n' >&2
    printf 'HINT: complete first wg-easy setup (Web UI over the SSH tunnel, or INIT_* one-shot vars).\n' >&2
    exit 1
  fi
  printf 'NOTE: no WireGuard interface yet; this is expected BEFORE first onboarding.\n' >&2
  exit 2
fi

# --- Actual listen port vs expected ------------------------------------------
actual_port=""
if ! actual_port="$(edge_wg_cmd show "${iface}" listen-port 2>/dev/null | tr -d '[:space:]')"; then
  state_error "failed to read listen port for ${iface}"
fi

if [[ -n "${actual_port}" && "${actual_port}" != "${expected_port}" ]]; then
  emit "STATE=MISMATCH"
  emit "interface=${iface}"
  emit "listen_port=${actual_port}"
  emit "expected_port=${expected_port}"
  emit "peers=0"
  emit "handshake=no"
  emit "handshake_fresh=no"
  emit "handshake_age_seconds="
  emit "handshake_max_age_seconds=${handshake_max_age}"
  printf 'ERROR: actual WireGuard listen port %s does not match expected port %s.\n' "${actual_port}" "${expected_port}" >&2
  printf 'REPAIR: open the wg-easy admin UI (SSH tunnel) -> set Port to %s, or review EDGE_WIREGUARD_PORT in %s before redeploying. The host UDP publish is also %s, so a mismatch breaks client reachability.\n' "${expected_port}" "${EDGE_ENV_FILE}" "${expected_port}" >&2
  printf 'Do not edit wg-easy persistent state behind the operator: change it through the admin UI and re-run this check.\n' >&2
  exit 1
fi

# --- Peers and handshake freshness -------------------------------------------
peers_out=""
if ! peers_out="$(edge_wg_cmd show "${iface}" peers 2>/dev/null)"; then
  state_error "failed to read peers for ${iface}"
fi
peer_count="$(printf '%s\n' "${peers_out}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')"

hs_out=""
if ! hs_out="$(edge_wg_cmd show "${iface}" latest-handshakes 2>/dev/null)"; then
  state_error "failed to read handshake state for ${iface}"
fi

# `wg latest-handshakes` prints "<pubkey>\t<unix-seconds>" (0 = never).
# P8 needs current evidence, so select the newest timestamp and compare its age
# with EDGE_HANDSHAKE_MAX_AGE_S instead of treating any historical timestamp
# greater than zero as a live client.
latest_handshake_epoch=0
while IFS=$'\t' read -r _ ts; do
  [[ "${ts:-0}" =~ ^[0-9]+$ ]] || continue
  if (( ts > latest_handshake_epoch )); then
    latest_handshake_epoch="${ts}"
  fi
done <<< "${hs_out}"

has_handshake=0
handshake_fresh=0
handshake_age=""
if (( latest_handshake_epoch > 0 )); then
  has_handshake=1
  now_epoch="$(date +%s)"
  if (( latest_handshake_epoch > now_epoch + 60 )); then
    state_error "latest WireGuard handshake is more than 60s in the future; host/container clock may be incorrect"
  fi
  if (( latest_handshake_epoch > now_epoch )); then
    handshake_age=0
  else
    handshake_age=$((now_epoch - latest_handshake_epoch))
  fi
  if (( handshake_age <= handshake_max_age )); then
    handshake_fresh=1
  fi
fi

# The state is decided before any normal-path output so consumers can safely
# use `head -n1` as well as key-based parsers.
if [[ "${handshake_fresh}" -eq 1 ]]; then
  state="HANDSHAKE_OK"
else
  state="READY_NO_HANDSHAKE"
fi

emit "STATE=${state}"
emit "interface=${iface}"
if [[ -z "${actual_port}" ]]; then
  emit "listen_port=(unknown)"
else
  emit "listen_port=${actual_port}"
fi
emit "expected_port=${expected_port}"
emit "peers=${peer_count}"
if [[ "${has_handshake}" -eq 1 ]]; then
  emit "handshake=yes"
else
  emit "handshake=no"
fi
if [[ "${handshake_fresh}" -eq 1 ]]; then
  emit "handshake_fresh=yes"
else
  emit "handshake_fresh=no"
fi
emit "handshake_age_seconds=${handshake_age}"
emit "handshake_max_age_seconds=${handshake_max_age}"

if [[ "${handshake_fresh}" -eq 1 ]]; then
  printf 'OK: interface %s on UDP %s with %s peer(s); newest handshake age=%ss (<=%ss).\n' \
    "${iface}" "${actual_port}" "${peer_count}" "${handshake_age}" "${handshake_max_age}" >&2
  exit 0
fi

if [[ "${has_handshake}" -eq 1 ]]; then
  printf 'NOTE: interface %s on UDP %s with %s peer(s); newest handshake is stale (age=%ss > %ss).\n' \
    "${iface}" "${actual_port}" "${peer_count}" "${handshake_age}" "${handshake_max_age}" >&2
else
  printf 'OK: interface %s on UDP %s with %s peer(s); no handshake yet (client not connected or not started).\n' \
    "${iface}" "${actual_port}" "${peer_count}" >&2
fi
exit 0
