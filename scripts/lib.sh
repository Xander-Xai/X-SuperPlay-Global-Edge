#!/usr/bin/env bash
# Shared helpers for X-SuperPlay Global Edge operator scripts.
# Sourced by the scripts in this directory; not executable on its own.
# shellcheck shell=bash

EDGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDGE_COMPOSE_FILE="${EDGE_ROOT}/deploy/docker-compose.yml"
EDGE_ENV_FILE="${EDGE_ENV_FILE:-${EDGE_ROOT}/.env}"
# NOTE: EDGE_BACKUP_DIR default is owned by backup.sh/restore.sh (its consumers)
# so the library stays free of unused-variable warnings.

# Resolve the env file used by an operator command and print its path.
# Pure function: no side effects. Callers must capture the result and export
# it as EDGE_ENV_FILE at top level (edge_compose reads that variable).
#   EDGE_ENV_FILE="$(edge_resolve_env "${1:-}")" || exit 1
#   export EDGE_ENV_FILE
# Resolution order: explicit $1 wins, then $EDGE_ENV_FILE, then ${EDGE_ROOT}/.env.
edge_resolve_env() {
  local env_file="${1:-}"
  if [[ -z "${env_file}" ]]; then
    env_file="${EDGE_ENV_FILE:-${EDGE_ROOT}/.env}"
  fi
  if [[ ! -f "${env_file}" ]]; then
    printf 'ERROR: env file not found: %s\n' "${env_file}" >&2
    printf 'Hint: cp .env.example .env, then fill production values on the host.\n' >&2
    return 1
  fi
  printf '%s\n' "${env_file}"
}

edge_require_docker() {
  command -v docker >/dev/null 2>&1 || { printf 'ERROR: docker is required\n' >&2; return 1; }
  docker info >/dev/null 2>&1 || { printf 'ERROR: docker daemon is not running or not accessible\n' >&2; return 1; }
}

# Return whether a host listening port is already occupied.
# Usage: edge_port_used <port> <tcp|udp|t|u> [bind-address]
# Return: 0 = occupied, 1 = free, 2 = cannot determine / invalid input.
# This helper deliberately uses explicit ss flags (-ltn/-lun). The previous
# `ss -l t` / `ss -l u` construction is invalid on iproute2 and could turn a
# failed probe into a false "port free" result when stderr was suppressed.
edge_port_used() {
  local port="$1" proto="$2" bind="${3:-}" out=""
  [[ "${port}" =~ ^[0-9]+$ ]] || return 2
  (( port >= 1 && port <= 65535 )) || return 2

  case "${proto}" in
    tcp|t) proto=tcp ;;
    udp|u) proto=udp ;;
    *) return 2 ;;
  esac

  if command -v ss >/dev/null 2>&1; then
    if [[ "${proto}" == "tcp" ]]; then
      out="$(ss -H -ltn 2>/dev/null)" || return 2
    else
      out="$(ss -H -lun 2>/dev/null)" || return 2
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if [[ "${proto}" == "tcp" ]]; then
      if ! out="$(netstat -ltn 2>/dev/null)"; then
        # Windows netstat does not understand the Linux -ltn flags.  Its
        # equivalent includes all TCP sockets, so retain listening rows only.
        out="$(netstat -ano -p TCP 2>/dev/null)" || return 2
        out="$(printf '%s\n' "${out}" | awk '/LISTENING|LISTEN/ { print }')"
      fi
    else
      if ! out="$(netstat -lun 2>/dev/null)"; then
        # UDP has no listening state in Windows netstat; all bound UDP rows
        # are candidates for the occupied-port probe.
        out="$(netstat -ano -p UDP 2>/dev/null)" || return 2
      fi
    fi
  else
    return 2
  fi

  if [[ -n "${bind}" ]]; then
    printf '%s\n' "${out}" | grep -Eq "(^|[[:space:]])${bind}:${port}([[:space:]]|$)"
  else
    printf '%s\n' "${out}" | grep -Eq ":${port}([[:space:]]|$)"
  fi
}

# Poll the container health status until healthy or timeout (default 180s).
edge_wait_healthy() {
  local timeout_s="${1:-180}" elapsed=0 cid health
  cid="$(edge_compose ps -q wg-easy 2>/dev/null | head -n1)"
  [[ -n "${cid}" ]] || { printf 'ERROR: wg-easy container not found after start\n' >&2; return 1; }
  while (( elapsed < timeout_s )); do
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "${cid}" 2>/dev/null || echo unknown)"
    if [[ "${health}" == "healthy" ]]; then
      printf '[edge] wg-easy healthy after %ss\n' "${elapsed}"
      return 0
    fi
    if [[ "$(docker inspect -f '{{.State.Status}}' "${cid}" 2>/dev/null)" != "running" ]]; then
      printf 'ERROR: wg-easy exited before becoming healthy\n' >&2
      docker logs --tail 40 "${cid}" >&2 2>&1 || true
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  printf 'ERROR: wg-easy not healthy within %ss (last=%s)\n' "${timeout_s}" "${health}" >&2
  docker logs --tail 40 "${cid}" >&2 2>&1 || true
  return 1
}

# Convert a POSIX-style path to the native form Docker expects on Windows
# (Git Bash / MSYS). On Linux/macOS this is a no-op passthrough.
edge_native() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "${p}" 2>/dev/null || printf '%s\n' "${p}"
  else
    printf '%s\n' "${p}"
  fi
}

# Compose wrapper so every script renders from the same env file + compose file.
edge_compose() {
  docker compose \
    --env-file "$(edge_native "${EDGE_ENV_FILE}")" \
    -f "$(edge_native "${EDGE_COMPOSE_FILE}")" \
    "$@"
}

# Project name exactly as Compose resolves it (name: field with env default).
edge_project_name() {
  edge_compose config --format json 2>/dev/null | tr ',' '\n' | sed -n 's/^.*"name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

# Name of the persistent WireGuard volume owned by this project.
edge_wg_volume() {
  local project
  project="$(edge_project_name)"
  [[ -n "${project}" ]] || return 1
  docker volume ls --filter "label=com.docker.compose.project=${project}" --format '{{.Name}}' \
    | grep -E "_etc_wireguard$" | head -n1
}

edge_require_volume() {
  local volume
  volume="$(edge_wg_volume)"
  if [[ -z "${volume}" ]]; then
    printf 'ERROR: WireGuard volume not found. Deploy the stack first (scripts/deploy.sh).\n' >&2
    return 1
  fi
  printf '%s\n' "${volume}"
}

# Return 0 if the wg-easy container is currently running (compose ps lists
# it), 1 otherwise (stopped, exited, or absent). Used by backup/restore to
# preserve the original service state instead of guessing.
edge_wg_running() {
  [[ -n "$(edge_compose ps -q wg-easy 2>/dev/null | head -n1)" ]]
}

# Archive a Docker volume to a single .tgz artifact using the pinned alpine
# helper. Usage: edge_tar_volume <volume> <absolute-out-file>
edge_tar_volume() {
  local volume="$1" out_file="$2"
  docker run --rm \
    -v "${volume}:/data:ro" \
    -v "$(edge_native "$(dirname "${out_file}")"):/backup" \
    alpine:3.20 \
    tar czf "/backup/$(basename "${out_file}")" -C /data .
}

edge_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

edge_info() {
  printf '[edge] %s\n' "$*"
}

edge_warn() {
  printf '[warn] %s\n' "$*" >&2
}
