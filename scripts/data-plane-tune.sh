#!/usr/bin/env bash
# Enforce/audit the repository-owned WireGuard MTU and TCP MSS policy.
# Usage:
#   bash scripts/data-plane-tune.sh --check [env-file]
#   bash scripts/data-plane-tune.sh --apply [env-file]
#
# The wg-easy container owns the WireGuard network namespace, so MTU and
# FORWARD-chain TCPMSS rules are inspected/applied inside that container.
# --apply is idempotent. A fresh pre-onboarding container legitimately has no
# WireGuard interface yet and returns STATE=NOT_CONFIGURED / exit 2.
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

mode="check"
env_arg=""
for arg in "$@"; do
  case "${arg}" in
    --check) mode="check" ;;
    --apply) mode="apply" ;;
    -*) printf 'ERROR: unknown option: %s\n' "${arg}" >&2; exit 1 ;;
    *) env_arg="${arg}" ;;
  esac
done

EDGE_ENV_FILE="$(edge_resolve_env "${env_arg:-}")" || exit 1
export EDGE_ENV_FILE
edge_require_docker || { printf 'STATE=ERROR\n'; printf 'ERROR: docker daemon not reachable\n' >&2; exit 1; }

get_env() {
  grep -E "^$1=" "${EDGE_ENV_FILE}" | tail -n1 | cut -d= -f2- | tr -d '\r' || true
}

expected_mtu="$(get_env EDGE_WG_MTU)"
expected_mtu="${expected_mtu:-1280}"
[[ "${expected_mtu}" =~ ^[0-9]+$ ]] || { printf 'STATE=ERROR\n'; printf 'ERROR: EDGE_WG_MTU must be an integer\n' >&2; exit 1; }
(( expected_mtu >= 1200 && expected_mtu <= 1420 )) || {
  printf 'STATE=ERROR\n'
  printf 'ERROR: EDGE_WG_MTU must be between 1200 and 1420\n' >&2
  exit 1
}

cid="$(edge_compose ps -q wg-easy 2>/dev/null | head -n1)"
if [[ -z "${cid}" ]]; then
  printf 'STATE=ERROR\n'
  printf 'ERROR: wg-easy container is not running\n' >&2
  exit 1
fi

iface="$(docker exec "${cid}" wg show interfaces 2>/dev/null | awk '{print $1}' | head -n1 || true)"
if [[ -z "${iface}" ]]; then
  printf 'STATE=NOT_CONFIGURED\n'
  printf 'mode=%s\n' "${mode}"
  printf 'interface=\n'
  printf 'expected_mtu=%s\n' "${expected_mtu}"
  printf 'actual_mtu=\n'
  printf 'mss_clamp_in=no\n'
  printf 'mss_clamp_out=no\n'
  printf 'NOTE: no WireGuard interface yet; complete wg-easy onboarding, then re-run --apply.\n' >&2
  exit 2
fi

if ! docker exec "${cid}" sh -c 'command -v ip >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1'; then
  printf 'STATE=ERROR\n'
  printf 'ERROR: wg-easy container must provide both ip and iptables for data-plane tuning\n' >&2
  exit 1
fi

read_mtu() {
  docker exec "${cid}" ip -o link show dev "${iface}" 2>/dev/null \
    | sed -nE 's/.* mtu ([0-9]+).*/\1/p' \
    | head -n1
}

has_mss_rule() {
  local direction="$1"
  docker exec "${cid}" iptables -t mangle -C FORWARD \
    "${direction}" "${iface}" \
    -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1
}

apply_mss_rule() {
  local direction="$1"
  docker exec "${cid}" iptables -t mangle -A FORWARD \
    "${direction}" "${iface}" \
    -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --clamp-mss-to-pmtu >/dev/null
}

if [[ "${mode}" == "apply" ]]; then
  docker exec "${cid}" ip link set dev "${iface}" mtu "${expected_mtu}"
  has_mss_rule -i || apply_mss_rule -i
  has_mss_rule -o || apply_mss_rule -o
fi

actual_mtu="$(read_mtu)"
mss_in="no"
mss_out="no"
has_mss_rule -i && mss_in="yes"
has_mss_rule -o && mss_out="yes"

state="PASS"
if [[ "${actual_mtu}" != "${expected_mtu}" || "${mss_in}" != "yes" || "${mss_out}" != "yes" ]]; then
  state="NEEDS_APPLY"
fi

printf 'STATE=%s\n' "${state}"
printf 'mode=%s\n' "${mode}"
printf 'interface=%s\n' "${iface}"
printf 'expected_mtu=%s\n' "${expected_mtu}"
printf 'actual_mtu=%s\n' "${actual_mtu:-unknown}"
printf 'mss_clamp_in=%s\n' "${mss_in}"
printf 'mss_clamp_out=%s\n' "${mss_out}"

if [[ "${state}" == "PASS" ]]; then
  printf 'OK: %s MTU=%s and bidirectional TCP MSS clamping are present.\n' "${iface}" "${actual_mtu}" >&2
  exit 0
fi

printf 'ERROR: data-plane policy is not applied. Run: bash scripts/data-plane-tune.sh --apply %s\n' "${EDGE_ENV_FILE}" >&2
exit 1
