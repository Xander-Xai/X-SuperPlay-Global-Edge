#!/usr/bin/env bash
# Preflight: verify a host is ready for X-SuperPlay Global Edge deployment.
# Usage: scripts/preflight.sh [path-to-env-file]
# Exit 0 = PASS, 1 = FAIL. Failing checks are fatal; warnings are advisory.
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Resolve once at top level (pure resolver: no hidden side effects).
EDGE_ENV_FILE="$(edge_resolve_env "${1:-}")" || exit 1
export EDGE_ENV_FILE

failures=0
warnings=0

check() { # check <label> <status(0|1)> <detail...>
  local label="$1" ok="$2"
  shift 2
  if [[ "${ok}" -eq 0 ]]; then
    printf '  [PASS] %s\n' "${label}"
  else
    printf '  [FAIL] %s\n' "${label}"
    for line in "$@"; do
      printf '         %s\n' "${line}"
    done
    failures=$((failures + 1))
  fi
}

warn() {
  printf '  [WARN] %s\n' "$*"
  warnings=$((warnings + 1))
}

edge_info "Preflight for X-SuperPlay Global Edge"
printf '  env file : %s\n' "${EDGE_ENV_FILE}"
printf '  compose  : %s\n' "${EDGE_COMPOSE_FILE}"
printf '\n'

edge_env="$(grep -E '^EDGE_ENV=' "${EDGE_ENV_FILE}" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
edge_env="${edge_env:-local}"

# Port-listener probing is part of the production deployment gate. If the host
# cannot determine whether a required port is occupied, production must fail
# closed instead of interpreting the unknown state as deployable. Local/CI
# environments retain the previous advisory warning behavior.
port_probe_unknown() { # <label> <detail>
  local label="$1" detail="$2"
  if [[ "${edge_env}" == "production" ]]; then
    check "${label}" 1 "${detail}" "Install iproute2 (ss) or net-tools (netstat), then re-run preflight."
  else
    warn "${detail}"
  fi
}

# --- 1. OS ------------------------------------------------------------------
os_id=""
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  os_id="$(. /etc/os-release && printf '%s' "${ID:-unknown}")"
fi
if [[ "$(uname -s)" != "Linux" ]]; then
  check "Operating system is Linux" 1 "Found: $(uname -s). This stack targets a Linux host."
elif [[ "${os_id}" =~ ^(ubuntu|debian)$ ]]; then
  check "Operating system is Linux (${os_id})" 0
else
  if [[ "${EDGE_ALLOW_UNSUPPORTED_OS:-0}" == "1" ]]; then
    warn "Unsupported distro '${os_id:-unknown}' accepted via EDGE_ALLOW_UNSUPPORTED_OS=1"
  else
    check "Supported distro (ubuntu/debian)" 1 "Found: ${os_id:-unknown}. Override only for experiments with EDGE_ALLOW_UNSUPPORTED_OS=1."
  fi
fi

case "$(uname -m)" in
  x86_64|aarch64) check "Architecture supported ($(uname -m))" 0 ;;
  *) check "Architecture supported" 1 "Found: $(uname -m)" ;;
esac

# --- 2. Docker --------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  check "docker CLI present" 0
  if docker info >/dev/null 2>&1; then
    check "docker daemon reachable" 0
  else
    check "docker daemon reachable" 1 "Daemon not running or current user lacks access."
  fi
  if docker compose version >/dev/null 2>&1; then
    check "Docker Compose v2 present" 0
  else
    check "Docker Compose v2 present" 1 "docker compose plugin missing."
  fi
else
  check "docker CLI present" 1 "Install Docker Engine + Compose v2 plugin first."
fi

# --- 3. Kernel / WireGuard capability ----------------------------------------
kernel="$(uname -r 2>/dev/null || echo unknown)"
if [[ -e /sys/module/wireguard ]] || grep -q wireguard /proc/modules 2>/dev/null; then
  check "WireGuard kernel support (module loaded)" 0
elif modprobe wireguard >/dev/null 2>&1; then
  check "WireGuard kernel support (module loadable)" 0
elif [[ -e /dev/net/tun ]]; then
  warn "WireGuard module not verified; /dev/net/tun exists (userspace fallback may be used)"
else
  check "WireGuard kernel support" 1 "Module not loaded and /dev/net/tun missing. Kernel ${kernel} needs wireguard built-in or loadable."
fi

# --- 4. Ports ----------------------------------------------------------------
# Read intended ports from the env file. Missing keys surface through validate.sh.
wg_port="$(grep -E '^EDGE_WIREGUARD_PORT=' "${EDGE_ENV_FILE}" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
admin_port="$(grep -E '^WG_ADMIN_PORT=' "${EDGE_ENV_FILE}" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
admin_bind="$(grep -E '^WG_ADMIN_BIND=' "${EDGE_ENV_FILE}" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"

# Idempotent redeploys legitimately find ports occupied by the already-running
# wg-easy container. Distinguish that from an unrelated process: occupied is
# accepted only when Docker proves this exact Compose service publishes the
# expected port/protocol (and bind for the admin surface).
existing_cid="$(edge_compose ps -q wg-easy 2>/dev/null | head -n1 || true)"
stack_owns_port() { # <port> <tcp|udp> [bind]
  local port="$1" proto="$2" bind="${3:-}" published=""
  [[ -n "${existing_cid}" ]] || return 1
  published="$(docker port "${existing_cid}" "${port}/${proto}" 2>/dev/null || true)"
  [[ -n "${published}" ]] || return 1
  if [[ -n "${bind}" ]]; then
    printf '%s\n' "${published}" | grep -Fxq "${bind}:${port}"
  else
    printf '%s\n' "${published}" | grep -Eq ":${port}$"
  fi
}

if [[ -n "${wg_port}" ]]; then
  if edge_port_used "${wg_port}" udp; then
    if stack_owns_port "${wg_port}" udp; then
      check "WireGuard UDP port ${wg_port} owned by existing project stack" 0
    else
      check "WireGuard UDP port ${wg_port} available to project" 1 "Port is already listening and is not published by this project's wg-easy container."
    fi
  else
    rc=$?
    if [[ "${rc}" -eq 1 ]]; then
      check "WireGuard UDP port ${wg_port} free" 0
    else
      port_probe_unknown \
        "WireGuard UDP port ${wg_port} availability verifiable" \
        "Cannot verify WireGuard UDP port ${wg_port} availability (no usable ss/netstat probe)."
    fi
  fi
fi

if [[ -n "${admin_port}" && "${admin_bind:-127.0.0.1}" == "127.0.0.1" ]]; then
  if edge_port_used "${admin_port}" tcp "127.0.0.1"; then
    if stack_owns_port "${admin_port}" tcp "127.0.0.1"; then
      check "Admin TCP port ${admin_port} owned by existing project stack (loopback)" 0
    else
      check "Admin TCP port ${admin_port} available to project" 1 "Loopback port is already listening and is not published by this project's wg-easy container."
    fi
  else
    rc=$?
    if [[ "${rc}" -eq 1 ]]; then
      check "Admin TCP port ${admin_port} free (loopback)" 0
    else
      port_probe_unknown \
        "Admin TCP port ${admin_port} availability verifiable" \
        "Cannot verify admin TCP port ${admin_port} availability (no usable ss/netstat probe)."
    fi
  fi
fi

# --- 5. Production resource floor -------------------------------------------
# Local/CI keeps a deliberately small engineering floor. Production is stricter
# because the selected purchase target is a 2C2G class host with operational
# headroom for Docker, upgrades, logs, and troubleshooting.
if [[ "${edge_env}" == "production" ]]; then
  min_free_gb=8
  min_mem_mb=1500
  min_cpu=2
else
  min_free_gb=2
  min_mem_mb=512
  min_cpu=1
fi

cpu_count="$(nproc 2>/dev/null || echo 0)"
if [[ "${cpu_count}" =~ ^[0-9]+$ ]] && (( cpu_count >= min_cpu )); then
  check "CPU >= ${min_cpu} vCPU (${edge_env})" 0
else
  check "CPU >= ${min_cpu} vCPU (${edge_env})" 1 "Detected: ${cpu_count:-unknown}"
fi

free_kb="$(df -Pk "${EDGE_ROOT}" 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ -n "${free_kb}" ]]; then
  free_gb=$((free_kb / 1024 / 1024))
  if (( free_gb >= min_free_gb )); then
    check "Disk free >= ${min_free_gb} GB on ${EDGE_ROOT} (${edge_env})" 0
  else
    check "Disk free >= ${min_free_gb} GB on ${EDGE_ROOT} (${edge_env})" 1 "~${free_gb} GB free"
  fi
else
  warn "Cannot determine free disk space on ${EDGE_ROOT}."
fi

mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)"
if [[ -n "${mem_kb}" ]]; then
  mem_mb=$((mem_kb / 1024))
  if (( mem_mb >= min_mem_mb )); then
    check "Memory >= ${min_mem_mb} MB (${edge_env})" 0
  else
    check "Memory >= ${min_mem_mb} MB (${edge_env})" 1 "~${mem_mb} MB detected"
  fi
fi

# --- 6. Configuration contract ---------------------------------------------
if "${SCRIPT_DIR}/validate.sh" "${EDGE_ENV_FILE}" >/dev/null 2>&1; then
  check "Configuration validation (validate.sh)" 0
else
  check "Configuration validation (validate.sh)" 1 "Run: bash scripts/validate.sh ${EDGE_ENV_FILE}"
fi

# --- 7. Network model sanity ------------------------------------------------
public_host="$(grep -E '^EDGE_PUBLIC_HOST=' "${EDGE_ENV_FILE}" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
disable_ipv6="$(grep -E '^EDGE_DISABLE_IPV6=' "${EDGE_ENV_FILE}" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
if [[ "${edge_env}" == "production" && -z "${public_host}" ]]; then
  check "EDGE_PUBLIC_HOST set for production env" 1 "EDGE_ENV=production requires a non-empty EDGE_PUBLIC_HOST (expected public endpoint)."
else
  check "Network model consistent (EDGE_ENV=${edge_env})" 0
fi
if [[ "${disable_ipv6}" != "true" ]]; then
  warn "EDGE_DISABLE_IPV6=${disable_ipv6:-unset} — G1 policy is IPv4-first (EDGE_DISABLE_IPV6=true)."
fi

printf '\n'
if (( failures > 0 )); then
  printf 'RESULT: FAIL (%d failure(s), %d warning(s))\n' "${failures}" "${warnings}"
  exit 1
fi
printf 'RESULT: PASS (%d warning(s))\n' "${warnings}"
