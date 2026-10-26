#!/usr/bin/env bash
# Apply or audit the repository-owned edge data-plane sysctl profile.
# Usage:
#   bash scripts/data-plane-sysctl.sh --check [env-file]
#   bash scripts/data-plane-sysctl.sh --apply [env-file]
#   bash scripts/data-plane-sysctl.sh --rollback [env-file]
#
# The repository tunes the kernel only after evidence exists
# (docs/operations.md). --apply therefore refuses to run unless
# EDGE_SYSCTL_ACK=1 is set in the env file and a server-state capture
# labelled T0 younger than EDGE_SYSCTL_EVIDENCE_MAX_AGE_S is present.
# --apply records the previous values so --rollback can restore them.
#
# This script touches only the keys listed in the selected profile plus the
# optional ethtool/cake steps. It never changes Docker daemon configuration
# and never turns GRO/GSO off.
# shellcheck shell=bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

SYSCTL_TARGET="/etc/sysctl.d/99-edge-latency.conf"
STATE_DIR="${EDGE_ROOT}/.temp"
ROLLBACK_FILE="${STATE_DIR}/sysctl-T0.txt"
ETHTOOL_ROLLBACK_FILE="${STATE_DIR}/ethtool-T0.txt"

mode="check"
env_arg=""
for arg in "$@"; do
  case "${arg}" in
    --check) mode="check" ;;
    --apply) mode="apply" ;;
    --rollback) mode="rollback" ;;
    -*) printf 'ERROR: unknown option: %s\n' "${arg}" >&2; exit 1 ;;
    *) env_arg="${arg}" ;;
  esac
done

EDGE_ENV_FILE="$(edge_resolve_env "${env_arg:-}")" || exit 1
export EDGE_ENV_FILE

get_env() {
  grep -E "^$1=" "${EDGE_ENV_FILE}" | tail -n1 | cut -d= -f2- | tr -d '\r' || true
}

profile_name="$(get_env EDGE_SYSCTL_PROFILE)"
profile_name="${profile_name:-edge-2c2g-30m}"
profile_file="${EDGE_ROOT}/deploy/sysctl/${profile_name}.sysctl"
if [[ ! -f "${profile_file}" ]]; then
  printf 'STATE=ERROR\n'
  printf 'ERROR: unknown sysctl profile: %s\n' "${profile_name}" >&2
  exit 1
fi

evidence_file="$(get_env EDGE_SYSCTL_EVIDENCE_FILE)"
evidence_file="${evidence_file:-${STATE_DIR}/server-state-T0.json}"
evidence_max_age="$(get_env EDGE_SYSCTL_EVIDENCE_MAX_AGE_S)"
evidence_max_age="${evidence_max_age:-86400}"
if [[ ! "${evidence_max_age}" =~ ^[0-9]+$ ]]; then
  printf 'STATE=ERROR\n'
  printf 'ERROR: EDGE_SYSCTL_EVIDENCE_MAX_AGE_S must be an integer\n' >&2
  exit 1
fi

ack="$(get_env EDGE_SYSCTL_ACK)"
cake_enabled="$(get_env EDGE_ENABLE_CAKE)"
cake_iface="$(get_env EDGE_CAKE_IFACE)"
cake_rate="$(get_env EDGE_CAKE_RATE)"
cake_rate="${cake_rate:-28mbit}"
ethtool_iface="$(get_env EDGE_ETHTOOL_IFACE)"

evidence_state="MISSING"
evidence_reason="no server-state capture at ${evidence_file}"

check_evidence() {
  if [[ ! -f "${evidence_file}" ]]; then
    evidence_reason="no server-state capture at ${evidence_file}"
    return 1
  fi
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "${evidence_file}" >/dev/null 2>&1; then
    evidence_reason="server-state capture is not valid JSON: ${evidence_file}"
    return 1
  fi
  local label
  local age
  local now
  local mtime
  label="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("label", ""))' "${evidence_file}" 2>/dev/null || printf '')"
  if [[ "${label}" != T0* ]]; then
    evidence_reason="server-state capture label is '${label:-missing}', expected T0"
    return 1
  fi
  now="$(date -u +%s)"
  mtime="$(stat -c %Y "${evidence_file}" 2>/dev/null || printf '')"
  if [[ -z "${mtime}" ]]; then
    evidence_reason="cannot read the age of ${evidence_file}"
    return 1
  fi
  age=$(( now - mtime ))
  if (( age > evidence_max_age )); then
    evidence_reason="server-state capture is ${age}s old, limit is ${evidence_max_age}s"
    return 1
  fi
  evidence_state="PRESENT"
  evidence_reason="server-state capture ${evidence_file} (${age}s old, label ${label})"
  return 0
}

profile_entries() {
  sed -nE 's/^[[:space:]]*([a-z0-9_.]+)[[:space:]]*=[[:space:]]*([^#]*[^[:space:]])[[:space:]]*$/\1|\2/p' "${profile_file}"
}

read_current() {
  sysctl -n "$1" 2>/dev/null | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//' || true
}

normalize() {
  printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

if [[ "${mode}" != "rollback" ]]; then
  if ! command -v sysctl >/dev/null 2>&1; then
    printf 'STATE=ERROR\n'
    printf 'ERROR: sysctl is required and this command must run on the Linux edge host\n' >&2
    exit 1
  fi
fi

if [[ "${mode}" == "apply" ]]; then
  if [[ "${ack}" != "1" ]]; then
    printf 'STATE=BLOCKED\n'
    printf 'GATE=ACK_REQUIRED\n'
    printf 'ERROR: EDGE_SYSCTL_ACK must be 1 in %s before applying the data-plane profile\n' "${EDGE_ENV_FILE}" >&2
    exit 1
  fi
  if ! check_evidence; then
    printf 'STATE=BLOCKED\n'
    printf 'GATE=EVIDENCE_MISSING\n'
    printf 'ERROR: %s\n' "${evidence_reason}" >&2
    printf 'Collect it first: bash scripts/g1-v2-server-state.sh %s T0\n' "${evidence_file}" >&2
    exit 1
  fi
else
  check_evidence || true
fi

if [[ "${mode}" == "apply" ]]; then
  mkdir -p "${STATE_DIR}"
  rollback_content=""
  while IFS='|' read -r key desired; do
    [[ -n "${key}" ]] || continue
    current="$(read_current "${key}")"
    rollback_content="${rollback_content}${key}=${current}"$'\n'
  done < <(profile_entries)
  printf '%s' "${rollback_content}" > "${ROLLBACK_FILE}"

  install -m 0644 "${profile_file}" "${SYSCTL_TARGET}"
  sysctl_log="${STATE_DIR}/sysctl-apply.log"
  sysctl -p "${SYSCTL_TARGET}" >"${sysctl_log}" 2>&1 || true
  if grep -qi 'error' "${sysctl_log}"; then
    edge_warn "sysctl reported errors while applying the profile:"
    grep -i 'error' "${sysctl_log}" >&2 || true
  fi

  if [[ -n "${ethtool_iface}" ]] && command -v ethtool >/dev/null 2>&1; then
    if ! ethtool -k "${ethtool_iface}" > "${ETHTOOL_ROLLBACK_FILE}" 2>/dev/null; then
      : > "${ETHTOOL_ROLLBACK_FILE}"
    fi
    for feature in gro gso tx-udp-segmentation rx-udp-gro-forwarding; do
      if ! ethtool -K "${ethtool_iface}" "${feature}" on >/dev/null 2>&1; then
        edge_warn "could not enable ${feature} on ${ethtool_iface}"
      fi
    done
  elif [[ -n "${ethtool_iface}" ]]; then
    edge_warn "ethtool is not installed; offload features were left untouched"
  fi

  if [[ "${cake_enabled}" == "1" ]]; then
    if [[ -z "${cake_iface}" ]]; then
      edge_warn "EDGE_ENABLE_CAKE=1 but EDGE_CAKE_IFACE is empty; cake was not applied"
    elif ! command -v tc >/dev/null 2>&1; then
      edge_warn "tc is not installed; cake was not applied"
    elif ! tc qdisc replace dev "${cake_iface}" root cake bandwidth "${cake_rate}" >/dev/null 2>&1; then
      edge_warn "could not apply cake shaping on ${cake_iface}"
    fi
  fi
fi

if [[ "${mode}" == "rollback" ]]; then
  if [[ ! -f "${ROLLBACK_FILE}" ]]; then
    printf 'STATE=ERROR\n'
    printf 'ERROR: no rollback state at %s; nothing was applied by this script\n' "${ROLLBACK_FILE}" >&2
    exit 1
  fi
  while IFS= read -r line; do
    [[ "${line}" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    [[ -n "${value}" ]] || continue
    sysctl -w "${key}=${value}" >/dev/null 2>&1 || edge_warn "could not restore ${key}"
  done < "${ROLLBACK_FILE}"
  rm -f "${SYSCTL_TARGET}"

  if [[ -f "${ETHTOOL_ROLLBACK_FILE}" && -n "${ethtool_iface}" ]]; then
    for pair in "gro:generic-receive-offload" "gso:generic-segmentation-offload" "tx-udp-segmentation:tx-udp-segmentation" "rx-udp-gro-forwarding:rx-udp-gro-forwarding"; do
      feature="${pair%%:*}"
      reported="${pair#*:}"
      was="$(grep -E "^[[:space:]]*${reported}:" "${ETHTOOL_ROLLBACK_FILE}" 2>/dev/null | head -n1 | awk '{print $2}')"
      if [[ "${was}" == "off" ]]; then
        ethtool -K "${ethtool_iface}" "${feature}" off >/dev/null 2>&1 || edge_warn "could not restore ${feature} on ${ethtool_iface}"
      fi
    done
  fi

  if [[ "${cake_enabled}" == "1" && -n "${cake_iface}" ]] && command -v tc >/dev/null 2>&1; then
    tc qdisc del dev "${cake_iface}" root >/dev/null 2>&1 || true
    tc qdisc replace dev "${cake_iface}" root fq >/dev/null 2>&1 || edge_warn "could not restore the fq qdisc on ${cake_iface}"
  fi

  printf 'STATE=ROLLED_BACK\n'
  printf 'mode=rollback\n'
  printf 'profile=%s\n' "${profile_name}"
  printf 'restored_from=%s\n' "${ROLLBACK_FILE}"
  exit 0
fi

drift=0
while IFS='|' read -r key desired; do
  [[ -n "${key}" ]] || continue
  desired="$(normalize "${desired}")"
  current="$(read_current "${key}")"
  if [[ "${current}" == "${desired}" ]]; then
    printf '%s=%s\n' "${key}" "${current}"
  else
    printf '%s=%s current=%s\n' "${key}" "${desired}" "${current:-unknown}"
    drift=$(( drift + 1 ))
  fi
done < <(profile_entries)

state="DRIFT"
if [[ "${drift}" -eq 0 ]]; then
  state="OK"
fi
bbr_available="no"
if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | tr ' ' '\n' | grep -qx bbr; then
  bbr_available="yes"
fi

printf 'STATE=%s\n' "${state}"
printf 'mode=%s\n' "${mode}"
printf 'profile=%s\n' "${profile_name}"
printf 'profile_file=%s\n' "${profile_file}"
printf 'gate=%s\n' "${evidence_state}"
printf 'evidence=%s\n' "${evidence_reason}"
printf 'drift_count=%s\n' "${drift}"
printf 'bbr_available=%s\n' "${bbr_available}"

if [[ "${drift}" -ne 0 ]]; then
  printf 'ERROR: data-plane profile is not applied. Run: bash scripts/data-plane-sysctl.sh --apply %s\n' "${EDGE_ENV_FILE}" >&2
  exit 1
fi
printf 'OK: data-plane profile %s is applied.\n' "${profile_name}" >&2
