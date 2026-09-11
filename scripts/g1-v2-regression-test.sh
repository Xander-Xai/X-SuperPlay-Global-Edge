#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/deploy/g1-v2/docker-compose.yml"
runtime_dir="$ROOT_DIR/runtime/g1-v2"
mkdir -p "$runtime_dir"
runtime_dir="$(cd "$runtime_dir" && pwd -P)"
grep -Fq "\${G1_V2_RUNTIME_DIR:?G1_V2_RUNTIME_DIR must be an absolute canonical path}/xray:/etc/xray:ro" "$COMPOSE_FILE"
grep -Fq "\${G1_V2_RUNTIME_DIR:?G1_V2_RUNTIME_DIR must be an absolute canonical path}/hysteria:/etc/hysteria:ro" "$COMPOSE_FILE"
grep -Fq "RUNTIME_DIR=\"\$ROOT_DIR/runtime/g1-v2\"" "$ROOT_DIR/scripts/g1-v2-validate.sh"
grep -Fq "export G1_V2_RUNTIME_DIR=\"\$RUNTIME_DIR\"" "$ROOT_DIR/scripts/g1-v2-validate.sh"
grep -Fq "export G1_V2_RUNTIME_DIR=\"\$RUNTIME_DIR\"" "$ROOT_DIR/scripts/g1-v2-deploy.sh"
printf 'TEST_RUNTIME_PATH_IDENTITY=PASS\n'
fake_dir="$(mktemp -d)"
marker="$fake_dir/fallback.ready"
cat >"$fake_dir/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *" stop reality"* ]]; then sleep 2; : > "$G1_V2_TEST_MARKER"; fi
exit 0
FAKE
chmod +x "$fake_dir/docker"
set +e
failover_output="$(PATH="$fake_dir:$PATH" G1_V2_TEST_MARKER="$marker" bash "$ROOT_DIR/scripts/g1-v2-failover.sh" --yes --interval=1 --fallback-ready="test -f '$marker'" --primary-ready=true 2>&1)"
rc=$?
set -e
rm -rf "$fake_dir"
test "$rc" -eq 0 || { printf '%s\n' "$failover_output" >&2; exit 1; }
printf '%s\n' "$failover_output" | grep -Eq '^failure_injection_started_at=' || exit 1
elapsed="$(printf '%s\n' "$failover_output" | sed -n 's/^failover_elapsed_seconds=//p' | tail -n1)"
test -n "$elapsed" && test "$elapsed" -ge 2 && test "$elapsed" -le 30
printf 'TEST_FAILOVER_TIMER_INCLUDES_STOP=PASS elapsed_seconds=%s\n' "$elapsed"
PS_BIN="$(command -v pwsh || command -v powershell || true)"
test -n "$PS_BIN" || { printf 'PowerShell is required for soak regression.\n' >&2; exit 1; }
"$PS_BIN" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ROOT_DIR/scripts/g1-v2-regression-test.ps1"
