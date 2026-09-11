#!/usr/bin/env bash
# Controlled, reversible Reality -> Hysteria2 failover harness.
# It stops/restarts only the additive Reality service and never deletes config.
# shellcheck shell=bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/deploy/g1-v2/docker-compose.yml"
YES=0; FALLBACK_READY=''; PRIMARY_READY=''; INTERVAL=30; WINDOW=30
for arg in "$@"; do
  case "$arg" in
    --yes) YES=1 ;;
    --fallback-ready=*) FALLBACK_READY="$(printf '%s' "$arg" | cut -d= -f2-)" ;;
    --primary-ready=*) PRIMARY_READY="$(printf '%s' "$arg" | cut -d= -f2-)" ;;
    --interval=*) INTERVAL="$(printf '%s' "$arg" | cut -d= -f2-)" ;;
    --fallback-ready|--primary-ready) printf 'Use --fallback-ready=... and --primary-ready=...\n' >&2; exit 2 ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done
test "$YES" -eq 1 || { printf 'Refusing mutation without --yes.\n' >&2; exit 2; }
if [[ -z "$FALLBACK_READY" || -z "$PRIMARY_READY" ]]; then
  printf 'Both application-level readiness commands are required; process checks are insufficient.\n' >&2
  exit 2
fi
test -f "$COMPOSE_FILE" || { printf 'Missing additive Compose file.\n' >&2; exit 1; }
compose() { docker compose -f "$COMPOSE_FILE" "$@"; }
wait_ready() {
  deadline_epoch="$1"; command="$2"; label="$3"; started_epoch="$4"
  while :; do
    if bash -c "$command" >/dev/null 2>&1; then
      now="$(date +%s)"
      elapsed="$((now-started_epoch))"
      printf '%s_READY_AT=%s\n' "$label" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '%s_ELAPSED_SECONDS=%s\n' "$label" "$elapsed"; printf '%s\n' "$elapsed"; return 0
    fi
    now="$(date +%s)"
    test "$now" -lt "$deadline_epoch" || return 1
    sleep 1
  done
}
printf 'FAILOVER_HARNESS=START\n'
compose ps
failure_epoch="$(date +%s)"
failure_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'failure_injection_started_at=%s\n' "$failure_started_at"
compose stop reality
primary_stopped_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'primary_process_stopped_at=%s\n' "$primary_stopped_at"
fallback_elapsed="$(wait_ready "$((failure_epoch+WINDOW))" "$FALLBACK_READY" FALLBACK "$failure_epoch" | tee /dev/stderr | tail -n1)" || {
  printf 'FAILOVER=FAIL usable fallback was not proven within 30 seconds\n' >&2
  compose start reality >/dev/null 2>&1 || true
  exit 1
}
failover_elapsed_seconds="$fallback_elapsed"
fallback_first_success_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'fallback_first_success_at=%s\n' "$fallback_first_success_at"
printf 'failover_elapsed_seconds=%s\n' "$failover_elapsed_seconds"
test "$failover_elapsed_seconds" -le "$WINDOW" || { printf 'FAILOVER=FAIL elapsed exceeded %ss\n' "$WINDOW" >&2; exit 1; }
compose start reality
primary_deadline="$(( $(date +%s) + INTERVAL*2 ))"
if ! wait_ready "$primary_deadline" "$PRIMARY_READY" PRIMARY "$failure_epoch" >/dev/null; then
  printf 'RECOVERY=FAIL primary was not eligible within two health-check intervals\n' >&2
  exit 1
fi
printf 'FAILOVER=PASS RECOVERY=PASS\n'
printf 'NOTE=HY2 restart and independent SSH/WireGuard checks remain required by the operator runbook\n'
