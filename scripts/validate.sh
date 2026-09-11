#!/usr/bin/env bash
# Validate an env file against the X-SuperPlay Global Edge contract.
# Usage: bash scripts/validate.sh [path-to-env-file]   (default: .env.example)
# Exits 0 on PASS. Enforces: exact tag+digest image identity, loopback admin
# bind, integer and non-colliding ports, handshake/data-plane thresholds,
# no admin passwords in env, origin/client-endpoint separation,
# IPv4-first default for production, rejection of the legacy misleading
# WG_HOST/WG_PORT contract, and env-template <-> Compose consistency.
# shellcheck shell=bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/deploy/docker-compose.yml"
ENV_FILE="${1:-${ROOT_DIR}/.env.example}"
EXPECTED_IMAGE="ghcr.io/wg-easy/wg-easy:15.4.0@sha256:0e7bc9d34e86ddcaa92bc700d4d7dc9b33291dbc07ac8d13382f7c2095f949ec"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

native() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1" 2>/dev/null || printf '%s\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

command -v docker >/dev/null 2>&1 || fail "docker is required"
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required"
[[ -f "${COMPOSE_FILE}" ]] || fail "missing compose file: ${COMPOSE_FILE}"
[[ -f "${ENV_FILE}" ]] || fail "missing env file: ${ENV_FILE}"

get() { grep -E "^$1=" "${ENV_FILE}" | tail -n1 | cut -d= -f2- | tr -d '\r' || true; }

image="$(get WGEASY_IMAGE)"
edge_env="$(get EDGE_ENV)"
public_host="$(get EDGE_PUBLIC_HOST)"
wireguard_endpoint_host="$(get EDGE_WIREGUARD_ENDPOINT_HOST)"
disable_ipv6="$(get EDGE_DISABLE_IPV6)"
admin_bind="$(get WG_ADMIN_BIND)"
wg_port="$(get EDGE_WIREGUARD_PORT)"
admin_port="$(get WG_ADMIN_PORT)"
handshake_max_age="$(get EDGE_HANDSHAKE_MAX_AGE_S)"
wg_mtu="$(get EDGE_WG_MTU)"
payload_min_bytes="$(get EDGE_CLIENT_PAYLOAD_MIN_BYTES)"
payload_min_bps="$(get EDGE_CLIENT_MIN_DOWNLOAD_BPS)"
payload_max_time="$(get EDGE_CLIENT_PAYLOAD_MAX_TIME_S)"
path_min_mbps="$(get EDGE_PATH_MIN_TCP_MBPS)"
path_reject_mbps="$(get EDGE_PATH_REJECT_TCP_MBPS)"
path_udp_test_mbps="$(get EDGE_PATH_UDP_TEST_MBPS)"
path_udp_max_loss_pct="$(get EDGE_PATH_UDP_MAX_LOSS_PCT)"

[[ -n "${image}" ]] || fail "WGEASY_IMAGE must be set in ${ENV_FILE}"
[[ "${image}" =~ ^ghcr\.io/wg-easy/wg-easy:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]] \
  || fail "WGEASY_IMAGE must use tag+sha256 digest identity (got: ${image})"
[[ "${image}" == "${EXPECTED_IMAGE}" ]] \
  || fail "WGEASY_IMAGE must remain the reviewed exact artifact ${EXPECTED_IMAGE}; upgrades/digest changes require a repository change and review"

[[ "${admin_bind}" == "127.0.0.1" ]] || fail "WG_ADMIN_BIND must remain 127.0.0.1 (loopback-only admin surface)"

if grep -Eq '^(WG_HOST|WG_PORT)=' "${ENV_FILE}"; then
  fail "legacy WG_HOST/WG_PORT keys are rejected: they do not configure wg-easy v15. Use EDGE_PUBLIC_HOST / EDGE_WIREGUARD_ENDPOINT_HOST and EDGE_WIREGUARD_PORT instead"
fi

for pair in "EDGE_WIREGUARD_PORT:${wg_port}" "WG_ADMIN_PORT:${admin_port}"; do
  key="${pair%%:*}"
  value="${pair#*:}"
  [[ "${value}" =~ ^[0-9]+$ ]] || fail "${key} must be an integer"
  (( value >= 1 && value <= 65535 )) || fail "${key} must be between 1 and 65535"
done
[[ "${wg_port}" != "${admin_port}" ]] || fail "EDGE_WIREGUARD_PORT and WG_ADMIN_PORT must not collide"

[[ "${handshake_max_age}" =~ ^[0-9]+$ ]] || fail "EDGE_HANDSHAKE_MAX_AGE_S must be an integer"
(( handshake_max_age >= 60 && handshake_max_age <= 3600 )) \
  || fail "EDGE_HANDSHAKE_MAX_AGE_S must be between 60 and 3600 seconds"

[[ "${wg_mtu}" =~ ^[0-9]+$ ]] || fail "EDGE_WG_MTU must be an integer"
(( wg_mtu >= 1200 && wg_mtu <= 1420 )) \
  || fail "EDGE_WG_MTU must be between 1200 and 1420 (incident stabilization default: 1280)"

for pair in \
  "EDGE_CLIENT_PAYLOAD_MIN_BYTES:${payload_min_bytes}:32768:10485760" \
  "EDGE_CLIENT_MIN_DOWNLOAD_BPS:${payload_min_bps}:1024:104857600" \
  "EDGE_CLIENT_PAYLOAD_MAX_TIME_S:${payload_max_time}:10:300" \
  "EDGE_PATH_MIN_TCP_MBPS:${path_min_mbps}:1:10000" \
  "EDGE_PATH_REJECT_TCP_MBPS:${path_reject_mbps}:1:10000" \
  "EDGE_PATH_UDP_TEST_MBPS:${path_udp_test_mbps}:1:10000"; do
  key="${pair%%:*}"
  rest="${pair#*:}"
  value="${rest%%:*}"
  rest="${rest#*:}"
  min="${rest%%:*}"
  max="${rest#*:}"
  [[ "${value}" =~ ^[0-9]+$ ]] || fail "${key} must be an integer"
  (( value >= min && value <= max )) || fail "${key} must be between ${min} and ${max}"
done
(( path_reject_mbps <= path_min_mbps )) \
  || fail "EDGE_PATH_REJECT_TCP_MBPS must be <= EDGE_PATH_MIN_TCP_MBPS"
[[ "${path_udp_max_loss_pct}" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || fail "EDGE_PATH_UDP_MAX_LOSS_PCT must be numeric"
awk -v v="${path_udp_max_loss_pct}" 'BEGIN{exit !(v >= 0 && v <= 100)}' \
  || fail "EDGE_PATH_UDP_MAX_LOSS_PCT must be between 0 and 100"

if grep -Eq '^(INIT_PASSWORD|WG_ADMIN_PASSWORD|PASSWORD|SECRET|TOKEN|PRIVATE_KEY|PRIVKEY)=' "${ENV_FILE}"; then
  fail "secret material (passwords/tokens/private keys) does not belong in the runtime env file"
fi

validate_host_value() {
  local key="$1" value="$2"
  [[ -z "${value}" ]] && return 0
  if [[ "${value}" == *' '* || "${value}" == *'"'* || "${value}" == *"'"* ]]; then
    fail "${key} must not contain spaces or quotes"
  fi
  if [[ ! "${value}" =~ ^[A-Za-z0-9.:-]+$ ]]; then
    fail "${key} must be a plain IPv4/IPv6/hostname value (got: ${value})"
  fi
}

validate_host_value EDGE_PUBLIC_HOST "${public_host}"
validate_host_value EDGE_WIREGUARD_ENDPOINT_HOST "${wireguard_endpoint_host}"

if [[ "${edge_env}" == "production" && -z "${public_host}" ]]; then
  fail "EDGE_ENV=production requires EDGE_PUBLIC_HOST (the actual origin / expected VPN egress identity)"
fi

case "${disable_ipv6}" in
  true|false) ;;
  "") fail "EDGE_DISABLE_IPV6 must be set to true or false (G1 default: true)" ;;
  *) fail "EDGE_DISABLE_IPV6 must be 'true' or 'false' (got: ${disable_ipv6})" ;;
esac
if [[ "${edge_env}" == "production" && "${disable_ipv6}" != "true" ]]; then
  fail "EDGE_ENV=production requires EDGE_DISABLE_IPV6=true (G1 is IPv4-first; docs/acceptance.md)"
fi

compose_vars="$(grep -oE '\$\{[A-Z0-9_]+' "${COMPOSE_FILE}" | sed -E 's/^\$\{//' | sort -u)"
missing=0
for var in ${compose_vars}; do
  if ! grep -qE "^${var}=" "${ENV_FILE}"; then
    printf 'ERROR: %s is referenced by %s but not declared in %s\n' \
      "${var}" "${COMPOSE_FILE}" "${ENV_FILE}" >&2
    missing=1
  fi
done
(( missing == 0 )) || exit 1

docker compose --env-file "$(native "${ENV_FILE}")" -f "$(native "${COMPOSE_FILE}")" config --quiet

printf 'PASS: configuration is structurally valid (%s)\n' "${ENV_FILE}"
