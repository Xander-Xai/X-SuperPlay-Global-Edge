#!/usr/bin/env bash
# Bounded, local-only regression checks for the HY2 Compose safety guards.
# A temporary Docker shim blocks every mutating command, even if the guard
# under test regresses.
# shellcheck shell=bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT_DIR/scripts/g1-v2-deploy.sh"
EXPECTED_IMAGE='tobyxdd/hysteria:v2.12.2@sha256:9725222899831fd80ca802c4f6984b5f6ad96672248a25dd7d8f781f5029f87c'
TIMEOUT_SECONDS="${HY2_SAFETY_TEST_TIMEOUT_SECONDS:-15}"
tmp_dir="$(mktemp -d)"
shim_dir="$tmp_dir/bin"
runtime_dir="$tmp_dir/runtime"
mutation_log="$tmp_dir/docker-mutations.log"
mkdir -p "$shim_dir" "$runtime_dir/hysteria"
printf 'listen: :443\n' >"$runtime_dir/hysteria/config.yaml"
printf 'test-certificate-placeholder\n' >"$runtime_dir/hysteria/server.crt"
printf 'test-private-key-placeholder\n' >"$runtime_dir/hysteria/server.key"
: >"$mutation_log"
real_docker="$(command -v docker)"
test -n "$real_docker"
cat >"$shim_dir/docker" <<'SHIM'
#!/usr/bin/env bash
set -u
log="${HY2_TEST_DOCKER_MUTATION_LOG:?}"
real_docker="${HY2_TEST_REAL_DOCKER:?}"
block() {
  printf '%s\n' "$*" >>"$log"
  printf 'DOCKER_MUTATION_BLOCKED_BY_TEST_SHIM=YES\n' >&2
  exit 97
}
test "$#" -gt 0 || block '<empty argv>'
if test "$1" != compose; then
  case "$1" in
    info|version) exec "$real_docker" "$@" ;;
    *) block "$@" ;;
  esac
fi
action=''
for arg in "$@"; do
  case "$arg" in
    config) action=config; break ;;
    up|down|start|stop|restart|rm|create|run|pull|push|build) block "$@" ;;
  esac
done
test "$action" = config || block "$@"
exec "$real_docker" "$@"
SHIM
chmod 755 "$shim_dir/docker"
trap 'rm -rf "$tmp_dir"' EXIT

run_check() {
  timeout "$TIMEOUT_SECONDS" env \
    "PATH=$shim_dir:$PATH" \
    "HY2_TEST_REAL_DOCKER=$real_docker" \
    "HY2_TEST_DOCKER_MUTATION_LOG=$mutation_log" \
    "G1_V2_RUNTIME_DIR=$runtime_dir" \
    "$@" bash "$DEPLOY" --check-hy2
}

run_up() {
  timeout "$TIMEOUT_SECONDS" env \
    "PATH=$shim_dir:$PATH" \
    "HY2_TEST_REAL_DOCKER=$real_docker" \
    "HY2_TEST_DOCKER_MUTATION_LOG=$mutation_log" \
    "G1_V2_RUNTIME_DIR=$runtime_dir" \
    "$@" bash "$DEPLOY" --up-hy2
}

assert_no_mutation() {
  if test -s "$mutation_log"; then
    printf 'DOCKER_MUTATION_BLOCKED_BY_TEST_SHIM=YES\n' >&2
    printf 'REGRESSION_RESULT=FAIL\n' >&2
    exit 1
  fi
}

reviewed_output="$(run_check \
  HYSTERIA_IMAGE="$EXPECTED_IMAGE" \
  COMPOSE_PROJECT_NAME='x-superplay-global-edge' 2>&1)"
grep -q '^HY2_RESOLVED_IMAGE_PIN=PASS$' <<<"$reviewed_output"
grep -q '^G1_V2_PROJECT_NAME=x-superplay-global-edge-g1-v2$' <<<"$reviewed_output"
grep -q '^HY2_PROJECT_NAMESPACE_ISOLATED=PASS$' <<<"$reviewed_output"
assert_no_mutation
printf 'CHECK_HY2_ACCEPTS_REVIEWED_RESOLVED_IMAGE=PASS\n'
printf 'ROOT_COMPOSE_PROJECT_NAME_CANNOT_CAPTURE_HY2=PASS\n'

printf 'HYSTERIA_IMAGE=example.invalid/unreviewed:test\n' >"$tmp_dir/unreviewed.env"
set +e
unreviewed_output="$(run_check \
  COMPOSE_ENV_FILES="$tmp_dir/unreviewed.env" \
  COMPOSE_PROJECT_NAME='x-superplay-global-edge' 2>&1)"
unreviewed_status=$?
set -e
test "$unreviewed_status" -ne 0
grep -q '^HY2_RESOLVED_IMAGE_PIN=FAIL$' <<<"$unreviewed_output"
assert_no_mutation
printf 'CHECK_HY2_REJECTS_UNREVIEWED_RESOLVED_IMAGE=PASS\n'

set +e
unreviewed_up_output="$(run_up \
  COMPOSE_ENV_FILES="$tmp_dir/unreviewed.env" \
  COMPOSE_PROJECT_NAME='x-superplay-global-edge' \
  G1_V2_PORT_OWNERSHIP=PASS 2>&1)"
unreviewed_up_status=$?
set -e
test "$unreviewed_up_status" -ne 0
assert_no_mutation
grep -q '^HY2_RESOLVED_IMAGE_PIN=FAIL$' <<<"$unreviewed_up_output"
if grep -q '^G1_V2_HY2_LIFECYCLE=UP_SERVICE_SCOPED$' <<<"$unreviewed_up_output"; then
  exit 1
fi
printf 'UP_HY2_BLOCKS_UNREVIEWED_IMAGE=PASS\n'

set +e
collision_output="$(G1_V2_COMPOSE_PROJECT_NAME='x-superplay-global-edge' \
  timeout "$TIMEOUT_SECONDS" env bash "$DEPLOY" --check-hy2 2>&1)"
collision_status=$?
set -e
test "$collision_status" -ne 0
grep -q '^HY2_PROJECT_NAMESPACE_ISOLATED=FAIL$' <<<"$collision_output"
assert_no_mutation
printf 'WG_PROJECT_NAMESPACE_COLLISION_TEST=PASS\n'
printf 'IMAGE_GUARD_BLOCKED_BEFORE_MUTATION=YES\n'
printf 'DOCKER_MUTATION_ATTEMPTED=NO\n'
printf 'REAL_DOCKER_MUTATION_EXECUTED=NO\n'
printf 'REGRESSION_TEST_FAIL_SAFE=PASS\n'
