#!/usr/bin/env bash
# Guarded lifecycle for the additive G1 v2 Compose project.
# --check and --check-hy2 are read-only. --up-hy2/--down-hy2 are service-scoped
# operations; neither can recreate or stop the existing Reality/WireGuard plane.
# The current wg-easy project is never modified.
# shellcheck shell=bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT_DIR/deploy/g1-v2/docker-compose.yml"
RUNTIME_DIR="$(printenv G1_V2_RUNTIME_DIR 2>/dev/null || true)"
test -n "$RUNTIME_DIR" || RUNTIME_DIR="$ROOT_DIR/runtime/g1-v2"
RUNTIME_DIR="$(realpath -m "$RUNTIME_DIR")"
export G1_V2_RUNTIME_DIR="$RUNTIME_DIR"
G1_V2_PROJECT_NAME="${G1_V2_COMPOSE_PROJECT_NAME:-x-superplay-global-edge-g1-v2}"
mode=check
for arg in "$@"; do
  case "$arg" in
    --check) mode=check ;;
    --check-hy2) mode=check-hy2 ;;
    --up) mode=up ;;
    --up-hy2) mode=up-hy2 ;;
    --down) mode=down ;;
    --down-hy2) mode=down-hy2 ;;
    *) printf 'Usage: scripts/g1-v2-deploy.sh [--check|--check-hy2|--up|--up-hy2|--down|--down-hy2]\n' >&2; exit 2 ;;
  esac
done
case "$mode" in
  check-hy2|up-hy2|down-hy2)
    if test "$G1_V2_PROJECT_NAME" = 'x-superplay-global-edge'; then
      printf 'HY2_PROJECT_NAMESPACE_ISOLATED=FAIL\n' >&2
      printf 'G1_V2_COMPOSE_PROJECT_NAME cannot target the existing WG project.\n' >&2
      exit 1
    fi
    ;;
esac
compose() { docker compose -p "$G1_V2_PROJECT_NAME" -f "$FILE" "$@"; }
check_hy2() {
  test -f "$FILE" || { printf 'Missing Compose file: %s\n' "$FILE" >&2; exit 1; }
  compose config --quiet
  expected_image='tobyxdd/hysteria:v2.12.2@sha256:9725222899831fd80ca802c4f6984b5f6ad96672248a25dd7d8f781f5029f87c'
  resolved_hy2_images="$(compose config --images | grep -E '^tobyxdd/hysteria:' || true)"
  resolved_hy2_count="$(printf '%s\n' "$resolved_hy2_images" | sed '/^$/d' | wc -l | tr -d ' ')"
  if test "$resolved_hy2_count" -ne 1 || test "$resolved_hy2_images" != "$expected_image"; then
    printf 'HY2_RESOLVED_IMAGE_PIN=FAIL\n' >&2
    printf 'HY2_RESOLVED_IMAGE=%s\n' "${resolved_hy2_images:-<none>}" >&2
    exit 1
  fi
  printf 'HY2_RESOLVED_IMAGE=%s\n' "$resolved_hy2_images"
  printf 'HY2_RESOLVED_IMAGE_PIN=PASS\n'
  printf 'G1_V2_PROJECT_NAME=%s\n' "$G1_V2_PROJECT_NAME"
  printf 'HY2_PROJECT_NAMESPACE_ISOLATED=PASS\n'
  test "$(realpath -m "$RUNTIME_DIR")" = "$RUNTIME_DIR" || {
    printf 'G1_V2_RUNTIME_DIR is not canonical: %s\n' "$RUNTIME_DIR" >&2; exit 1;
  }
  if test "${G1_V2_RUNTIME_VALIDATE:-0}" = 1; then
    test -s "$RUNTIME_DIR/hysteria/config.yaml" || { printf 'Missing rendered Hysteria config outside Git.\n' >&2; exit 1; }
    test -s "$RUNTIME_DIR/hysteria/server.crt" || { printf 'Missing external Hysteria TLS certificate.\n' >&2; exit 1; }
    test -s "$RUNTIME_DIR/hysteria/server.key" || { printf 'Missing external Hysteria TLS private key.\n' >&2; exit 1; }
  fi
  for secret_path in \
    'runtime/g1-v2/hysteria/config.yaml' \
    'runtime/g1-v2/hysteria/server.crt' \
    'runtime/g1-v2/hysteria/server.key'; do
    if git -C "$ROOT_DIR" ls-files --error-unmatch "$secret_path" >/dev/null 2>&1; then
      printf 'Tracked Hysteria runtime secret detected: %s\n' "$secret_path" >&2; exit 1
    fi
  done
  printf 'G1_V2_HY2_CHECK=PASS\n'
}
case "$mode" in
  check)
    bash "$ROOT_DIR/scripts/g1-v2-validate.sh"
    compose config --quiet
    printf 'G1_V2_LIFECYCLE=CHECK_ONLY\n'
    ;;
  check-hy2)
    check_hy2
    printf 'G1_V2_HY2_LIFECYCLE=CHECK_ONLY\n'
    ;;
  up)
    port_gate="$(printenv G1_V2_PORT_OWNERSHIP 2>/dev/null || true)"
    test "$port_gate" = PASS || {
      printf 'G1_V2_PORT_OWNERSHIP=PASS is required after real ss/Docker/firewall review.\n' >&2; exit 1;
    }
    test -s "$RUNTIME_DIR/xray/config.json" || { printf 'Missing rendered Xray config outside Git: %s\n' "$RUNTIME_DIR/xray/config.json" >&2; exit 1; }
    test -s "$RUNTIME_DIR/hysteria/config.yaml" || { printf 'Missing rendered Hysteria2 config outside Git: %s\n' "$RUNTIME_DIR/hysteria/config.yaml" >&2; exit 1; }
    bash "$ROOT_DIR/scripts/g1-v2-validate.sh"
    compose up -d
    printf 'G1_V2_LIFECYCLE=UP_PROCESS_CHECK_ONLY\n'
    printf 'Application probes and failover evidence are still required.\n'
    ;;
  up-hy2)
    port_gate="$(printenv G1_V2_PORT_OWNERSHIP 2>/dev/null || true)"
    test "$port_gate" = PASS || {
      printf 'G1_V2_PORT_OWNERSHIP=PASS is required after real ss/Docker/firewall review.\n' >&2; exit 1;
    }
    G1_V2_RUNTIME_VALIDATE=1 check_hy2
    compose up -d --no-deps hysteria2
    printf 'G1_V2_HY2_LIFECYCLE=UP_SERVICE_SCOPED\n'
    printf 'Hysteria process presence is not functional application evidence.\n'
    ;;
  down)
    compose down
    printf 'G1_V2_LIFECYCLE=DOWN\n'
    ;;
  down-hy2)
    compose stop hysteria2
    compose rm -sf hysteria2
    printf 'G1_V2_HY2_LIFECYCLE=DOWN_SERVICE_SCOPED\n'
    ;;
esac
