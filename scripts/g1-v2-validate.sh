#!/usr/bin/env bash
# Static contract checks for the additive G1 v2 server/client artifacts.
# This never starts a service and never treats a listening port as functional.
# shellcheck shell=bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/runtime/g1-v2"
mkdir -p "$RUNTIME_DIR"
RUNTIME_DIR="$(cd "$RUNTIME_DIR" && pwd -P)"
export G1_V2_RUNTIME_DIR="$RUNTIME_DIR"
cd "$ROOT_DIR"
pass=0
fail=0
check() {
  label="$1"; shift
  if "$@"; then printf '[PASS] %s\n' "$label"; pass=$((pass + 1))
  else printf '[FAIL] %s\n' "$label" >&2; fail=$((fail + 1)); fi
}
check_file() { test -f "$1"; }
check_regex() { grep -Eq "$1" "$2"; }
for file in deploy/g1-v2/docker-compose.yml deploy/g1-v2/xray/config.json.example \
  deploy/g1-v2/hysteria/config.yaml.example client/mihomo/config.yaml.example \
  docs/g1-v2-existing-component-disposition.md docs/g1-v2-port-ownership-adr.md; do
  check "required artifact $file" check_file "$file"
done
check 'Xray image is official, versioned and digest-pinned' check_regex \
  'ghcr\.io/xtls/xray-core:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}' deploy/g1-v2/docker-compose.yml
check 'Hysteria image is versioned and digest-pinned' check_regex \
  'tobyxdd/hysteria:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}' deploy/g1-v2/docker-compose.yml
check 'Reality template has VLESS + REALITY and TCP 443' bash -c \
  "grep -q vless deploy/g1-v2/xray/config.json.example && grep -q reality deploy/g1-v2/xray/config.json.example && grep -q '\"port\": 443' deploy/g1-v2/xray/config.json.example"
check 'Hysteria template is UDP 443 and conservative' bash -c \
  "grep -q 'listen: :443' deploy/g1-v2/hysteria/config.yaml.example && ! grep -Eq '(^|[[:space:]])(up|down):' deploy/g1-v2/hysteria/config.yaml.example"
check 'Mihomo group is application health-checked and ordered' bash -c \
  "grep -q 'name: GLOBAL-STABLE' client/mihomo/config.yaml.example && grep -q 'type: fallback' client/mihomo/config.yaml.example && grep -q 'interval: 30' client/mihomo/config.yaml.example && grep -q 'max-failed-times: 2' client/mihomo/config.yaml.example && grep -q 'empty-fallback: REJECT' client/mihomo/config.yaml.example"
check 'Mihomo does not enable TUN by default' check_regex '^  enable: false$' client/mihomo/config.yaml.example
check 'no private key material is present in templates' bash -c \
  "! grep -RInE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' deploy/g1-v2 client/mihomo"
if command -v python3 >/dev/null 2>&1; then
  check 'Xray example parses as JSON' python3 -c 'import json; json.load(open("deploy/g1-v2/xray/config.json.example", encoding="utf-8"))'
  check 'Mihomo example parses as YAML' python3 -c 'import yaml; yaml.safe_load(open("client/mihomo/config.yaml.example", encoding="utf-8"))'
else
  printf '[SKIP] python3 unavailable for JSON/YAML parser checks\n'
fi
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  check 'additive Compose file renders' docker compose -f deploy/g1-v2/docker-compose.yml config --quiet
else
  printf '[SKIP] Docker daemon unavailable; Compose render remains a CI/runtime check\n'
fi
if test "$fail" -eq 0; then result=PASS; else result=FAIL; fi
printf 'RESULT=%s passes=%s fails=%s PORT_OWNERSHIP=BLOCKED_UNTIL_REAL_RUNTIME\n' "$result" "$pass" "$fail"
test "$fail" -eq 0
