#!/usr/bin/env bash
# Repository self-test: failure-path + negative validation + doc link check.
# Usage: bash scripts/self-test.sh
# Runs without Docker where possible; Docker-dependent checks are skipped
# with a notice when the daemon is unavailable (CI runs them via the
# stack-lifecycle job instead).
# shellcheck shell=bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

pass=0
fail_count=0

t() { # t <description> <exit-code-expected> <cmd...>
  local desc="$1" expected="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then
    local actual=0
  else
    local actual=$?
  fi
  if [[ "${actual}" == "${expected}" ]]; then
    printf '  [PASS] %s\n' "${desc}"
    pass=$((pass + 1))
  else
    printf '  [FAIL] %s (expected exit %s, got %s)\n' "${desc}" "${expected}" "${actual}"
    fail_count=$((fail_count + 1))
  fi
}

have_docker=0
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && have_docker=1

printf '=== Script syntax ===\n'
for f in scripts/*.sh; do
  t "bash -n ${f}" 0 bash -n "${f}"
done

printf '=== Positive validation ===\n'
t 'validate.sh passes on .env.example' 0 bash scripts/validate.sh .env.example

printf '=== Negative validation (failure-path) ===\n'
# Repo-local temp dir (.temp/ is gitignored) keeps cleanup deterministic.
tmpdir="${ROOT_DIR}/.temp/self-test-$$"
mkdir -p "${tmpdir}"
listener_pids=()
cleanup() {
  local pid
  for pid in "${listener_pids[@]}"; do
    kill "${pid}" >/dev/null 2>&1 || true
  done
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

mkbad() { # mkbad <name> <sed-expr>
  sed "${2}" .env.example > "${tmpdir}/${1}"
}

mkbad bad-image 's#^WGEASY_IMAGE=.*#WGEASY_IMAGE=ghcr.io/wg-easy/wg-easy:latest#'
t 'reject floating :latest image' 1 bash scripts/validate.sh "${tmpdir}/bad-image"

mkbad bad-image2 's#^WGEASY_IMAGE=.*#WGEASY_IMAGE=ghcr.io/wg-easy/wg-easy:15.3.0#'
t 'reject unpinned/unreviewed image tag' 1 bash scripts/validate.sh "${tmpdir}/bad-image2"

mkbad bad-admin 's#^WG_ADMIN_BIND=.*#WG_ADMIN_BIND=0.0.0.0#'
t 'reject public admin bind' 1 bash scripts/validate.sh "${tmpdir}/bad-admin"

mkbad bad-port 's#^EDGE_WIREGUARD_PORT=.*#EDGE_WIREGUARD_PORT=notaport#'
t 'reject non-numeric WireGuard port' 1 bash scripts/validate.sh "${tmpdir}/bad-port"

mkbad out-of-range-port 's#^EDGE_WIREGUARD_PORT=.*#EDGE_WIREGUARD_PORT=70000#'
t 'reject out-of-range WireGuard port' 1 bash scripts/validate.sh "${tmpdir}/out-of-range-port"

mkbad collision 's#^WG_ADMIN_PORT=.*#WG_ADMIN_PORT=51820#'
t 'reject port collision' 1 bash scripts/validate.sh "${tmpdir}/collision"

mkbad bad-handshake-age 's#^EDGE_HANDSHAKE_MAX_AGE_S=.*#EDGE_HANDSHAKE_MAX_AGE_S=forever#'
t 'reject non-numeric handshake freshness window' 1 bash scripts/validate.sh "${tmpdir}/bad-handshake-age"

mkbad unsafe-handshake-age 's#^EDGE_HANDSHAKE_MAX_AGE_S=.*#EDGE_HANDSHAKE_MAX_AGE_S=86400#'
t 'reject overly broad handshake freshness window' 1 bash scripts/validate.sh "${tmpdir}/unsafe-handshake-age"

# Legacy misleading v14-era contract must be rejected outright (GE-PREP-001).
cp .env.example "${tmpdir}/legacy-wg-host"
printf 'WG_HOST=203.0.113.10\n' >> "${tmpdir}/legacy-wg-host"
t 'reject legacy WG_HOST key' 1 bash scripts/validate.sh "${tmpdir}/legacy-wg-host"

cp .env.example "${tmpdir}/legacy-wg-port"
printf 'WG_PORT=51900\n' >> "${tmpdir}/legacy-wg-port"
t 'reject legacy WG_PORT key' 1 bash scripts/validate.sh "${tmpdir}/legacy-wg-port"

cp .env.example "${tmpdir}/with-password"
printf 'INIT_%s=supersecret\n' 'PASSWORD' >> "${tmpdir}/with-password"
t 'reject admin password in env file' 1 bash scripts/validate.sh "${tmpdir}/with-password"

cp .env.example "${tmpdir}/prod-host"
printf 'EDGE_PUBLIC_HOST=203.0.113.10\n' >> "${tmpdir}/prod-host"
sed -i 's/^EDGE_ENV=.*/EDGE_ENV=production/' "${tmpdir}/prod-host"
t 'accept production env with EDGE_PUBLIC_HOST' 0 bash scripts/validate.sh "${tmpdir}/prod-host"

cp .env.example "${tmpdir}/prod-hostname"
printf 'EDGE_PUBLIC_HOST=vpn.example.com\n' >> "${tmpdir}/prod-hostname"
sed -i 's/^EDGE_ENV=.*/EDGE_ENV=production/' "${tmpdir}/prod-hostname"
t 'accept production env with hostname endpoint' 0 bash scripts/validate.sh "${tmpdir}/prod-hostname"

mkbad prod-nohost 's/^EDGE_ENV=.*/EDGE_ENV=production/'
t 'reject production env without EDGE_PUBLIC_HOST' 1 bash scripts/validate.sh "${tmpdir}/prod-nohost"

cp .env.example "${tmpdir}/bad-host-char"
printf 'EDGE_PUBLIC_HOST=203.0.113.10 extra\n' >> "${tmpdir}/bad-host-char"
t 'reject EDGE_PUBLIC_HOST with spaces' 1 bash scripts/validate.sh "${tmpdir}/bad-host-char"

cp .env.example "${tmpdir}/prod-ipv6"
printf 'EDGE_PUBLIC_HOST=203.0.113.10\n' >> "${tmpdir}/prod-ipv6"
sed -i 's/^EDGE_ENV=.*/EDGE_ENV=production/' "${tmpdir}/prod-ipv6"
sed -i 's/^EDGE_DISABLE_IPV6=.*/EDGE_DISABLE_IPV6=false/' "${tmpdir}/prod-ipv6"
t 'reject production env with IPv6 enabled (G1 is IPv4-first)' 1 bash scripts/validate.sh "${tmpdir}/prod-ipv6"

cp .env.example "${tmpdir}/bad-ipv6-value"
sed -i 's/^EDGE_DISABLE_IPV6=.*/EDGE_DISABLE_IPV6=yes/' "${tmpdir}/bad-ipv6-value"
t 'reject non-boolean EDGE_DISABLE_IPV6' 1 bash scripts/validate.sh "${tmpdir}/bad-ipv6-value"

t 'reject missing env file' 1 bash scripts/validate.sh "${tmpdir}/does-not-exist.env"

printf '=== Secret scan ===\n'
t 'secret-scan clean on repository' 0 bash scripts/secret-scan.sh

mkdir -p "${tmpdir}/leak"
# Fixtures assembled at runtime so this file itself never contains the literal
# secret shapes (the repository scan above would otherwise self-match).
pem_begin='-----BEGIN RSA '
pem_end='PRIVATE KEY-----'
# Single line: secret-scan matches per line, so a split fixture would never
# trigger the PEM pattern and the negative test would silently pass.
printf '%s%s\nMIIEow==\n' "${pem_begin}" "${pem_end}" > "${tmpdir}/leak/id_rsa"
t 'secret-scan detects PEM private key' 1 bash scripts/secret-scan.sh "${tmpdir}/leak"
rm -f "${tmpdir}/leak/id_rsa"

gh_prefix='ghp_'
printf '%s%s\n' "${gh_prefix}" '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ' > "${tmpdir}/leak/token"
t 'secret-scan detects GitHub token shape' 1 bash scripts/secret-scan.sh "${tmpdir}/leak"
rm -rf "${tmpdir}/leak"

printf '=== Host port probe regression ===\n'
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
if command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; then
  tcp_port_file="${tmpdir}/tcp-port"
  udp_port_file="${tmpdir}/udp-port"
  python3 -c 'import socket,sys,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); open(sys.argv[1],"w",encoding="utf-8").write(str(s.getsockname()[1])); time.sleep(30)' "${tcp_port_file}" &
  listener_pids+=("$!")
  python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("127.0.0.1",0)); open(sys.argv[1],"w",encoding="utf-8").write(str(s.getsockname()[1])); time.sleep(30)' "${udp_port_file}" &
  listener_pids+=("$!")
  for _ in {1..50}; do
    [[ -s "${tcp_port_file}" && -s "${udp_port_file}" ]] && break
    sleep 0.1
  done
  tcp_port="$(cat "${tcp_port_file}")"
  udp_port="$(cat "${udp_port_file}")"
  t 'detect occupied TCP loopback listener' 0 edge_port_used "${tcp_port}" tcp 127.0.0.1
  t 'detect occupied UDP listener' 0 edge_port_used "${udp_port}" udp
else
  printf '  [SKIP] no ss/netstat available for port-probe regression\n'
fi

printf '=== WireGuard checker (mock states) ===\n'
# Deterministic seam: EDGE_WG_MOCK_BIN replaces `docker exec <cid> wg` and
# EDGE_WG_FIXTURE selects per-invocation fixtures. This exercises every
# state machine branch without a real WireGuard interface or Docker daemon.
mockdir="${tmpdir}/wg-mock"
mkdir -p "${mockdir}"
cat > "${mockdir}/mock-wg" <<'EOF'
#!/usr/bin/env bash
# Mock `wg` for wireguard-check tests. Reads "<args>.out" (content) or
# "<args>.fail" (exit 1) from EDGE_WG_FIXTURE; otherwise prints nothing.
key="$*"
if [[ -f "${EDGE_WG_FIXTURE}/${key}.out" ]]; then
  cat "${EDGE_WG_FIXTURE}/${key}.out"
  exit 0
fi
if [[ -f "${EDGE_WG_FIXTURE}/${key}.fail" ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "${mockdir}/mock-wg"

mkwg() { # mkwg <fixture-name>  (no-args variant: --interfaces absent = empty)
  mkdir -p "${mockdir}/${1}"
}
mkgood() { # mkgood <fixture> <listen-port> <handshake:none|fresh|stale>
  local ts=0
  mkdir -p "${mockdir}/${1}"
  printf 'wg0\n' > "${mockdir}/${1}/show interfaces.out"
  printf '%s\n' "${2}" > "${mockdir}/${1}/show wg0 listen-port.out"
  printf 'PubKeyTest==\n' > "${mockdir}/${1}/show wg0 peers.out"
  case "${3}" in
    fresh) ts="$(date +%s)" ;;
    stale) ts="$(( $(date +%s) - 3600 ))" ;;
    none) ts=0 ;;
    *) printf 'invalid handshake fixture: %s\n' "${3}" >&2; exit 1 ;;
  esac
  printf 'PubKeyTest==\t%s\n' "${ts}" > "${mockdir}/${1}/show wg0 latest-handshakes.out"
}

t_state() { # t_state <desc> <expected-exit> <expected-state-substr> [expected-extra] <cmd...>
  local desc="$1" expected_rc="$2" expected_sub="$3" expected_extra="$4"
  shift 4
  local out="" rc=0
  out="$("$@" 2>/dev/null)" || rc=$?
  local ok=0
  if [[ "${rc}" == "${expected_rc}" && "${out}" == *"${expected_sub}"* && "${out}" == *"${expected_extra}"* ]]; then
    ok=1
  fi
  if [[ "${ok}" -eq 1 ]]; then
    printf '  [PASS] %s\n' "${desc}"
    pass=$((pass + 1))
  else
    printf '  [FAIL] %s (expected rc=%s + %s + %s, got rc=%s out=%q)\n' \
      "${desc}" "${expected_rc}" "${expected_sub}" "${expected_extra}" "${rc}" "${out}"
    fail_count=$((fail_count + 1))
  fi
}

# not configured: no interfaces -> STATE=NOT_CONFIGURED, rc=2 by default,
# rc=1 with --require-configured.
mkwg not-configured
t_state 'wg-check NOT_CONFIGURED before onboarding' 2 'STATE=NOT_CONFIGURED' 'handshake_fresh=no' \
  env EDGE_WG_MOCK_BIN="${mockdir}/mock-wg" EDGE_WG_FIXTURE="${mockdir}/not-configured" \
  bash scripts/wireguard-check.sh .env.example
t_state 'wg-check --require-configured fails when not configured' 1 'STATE=NOT_CONFIGURED' 'handshake_fresh=no' \
  env EDGE_WG_MOCK_BIN="${mockdir}/mock-wg" EDGE_WG_FIXTURE="${mockdir}/not-configured" \
  bash scripts/wireguard-check.sh --require-configured .env.example

# configured, no handshake -> READY_NO_HANDSHAKE, rc=0.
mkgood ready-no-peers 51820 none
t_state 'wg-check READY_NO_HANDSHAKE without handshake' 0 'STATE=READY_NO_HANDSHAKE' 'handshake_fresh=no' \
  env EDGE_WG_MOCK_BIN="${mockdir}/mock-wg" EDGE_WG_FIXTURE="${mockdir}/ready-no-peers" \
  bash scripts/wireguard-check.sh .env.example

# configured + recent handshake -> HANDSHAKE_OK, rc=0.
mkgood handshake-ok 51820 fresh
t_state 'wg-check HANDSHAKE_OK only for fresh handshake' 0 'STATE=HANDSHAKE_OK' 'handshake_fresh=yes' \
  env EDGE_WG_MOCK_BIN="${mockdir}/mock-wg" EDGE_WG_FIXTURE="${mockdir}/handshake-ok" \
  bash scripts/wireguard-check.sh .env.example

# Historical handshake beyond the freshness window must not pass P8.
mkgood stale-handshake 51820 stale
t_state 'wg-check rejects stale historical handshake as current evidence' 0 'STATE=READY_NO_HANDSHAKE' 'handshake_fresh=no' \
  env EDGE_WG_MOCK_BIN="${mockdir}/mock-wg" EDGE_WG_FIXTURE="${mockdir}/stale-handshake" \
  bash scripts/wireguard-check.sh .env.example

# listen-port mismatch -> STATE=MISMATCH, rc=1.
mkgood mismatch 51821 none
t_state 'wg-check MISMATCH on listen-port drift' 1 'STATE=MISMATCH' 'handshake_fresh=no' \
  env EDGE_WG_MOCK_BIN="${mockdir}/mock-wg" EDGE_WG_FIXTURE="${mockdir}/mismatch" \
  bash scripts/wireguard-check.sh .env.example

# wg tool failure -> STATE=ERROR, rc=1.
mkwg wg-error
: > "${mockdir}/wg-error/show interfaces.fail"
t_state 'wg-check ERROR on wg command failure' 1 'STATE=ERROR' '' \
  env EDGE_WG_MOCK_BIN="${mockdir}/mock-wg" EDGE_WG_FIXTURE="${mockdir}/wg-error" \
  bash scripts/wireguard-check.sh .env.example

printf '=== Documentation link check ===\n'
link_fail=0
while IFS= read -r md; do
  while IFS= read -r link; do
    case "${link}" in
      http://*|https://*|mailto:*|\#*) continue ;;
      *) ;;
    esac
    target="$(dirname "${md}")/${link}"
    if [[ ! -e "${target}" ]]; then
      printf '  [FAIL] broken link in %s -> %s\n' "${md}" "${link}"
      link_fail=1
    fi
  done < <(grep -oE '\]\([^)]+\)' "${md}" | sed -E 's/^\]\(//; s/\)$//' | grep -vE '^(http://|https://|mailto:|#)')
done < <(git ls-files '*.md')
if [[ "${link_fail}" -eq 0 ]]; then
  printf '  [PASS] all local documentation links resolve\n'
  pass=$((pass + 1))
else
  fail_count=$((fail_count + 1))
fi

printf '=== Docker-dependent (optional) ===\n'
if [[ "${have_docker}" -eq 1 ]]; then
  t 'compose renders with .env.example' 0 docker compose --env-file .env.example -f deploy/docker-compose.yml config --quiet
  render="$(
    docker compose --env-file .env.example -f deploy/docker-compose.yml config 2>/dev/null \
    || true
  )"
  if [[ "${render}" == *'DISABLE_IPV6: "true"'* ]]; then
    printf '  [PASS] IPv4-first render (DISABLE_IPV6=true)\n'
    pass=$((pass + 1))
  else
    printf '  [FAIL] IPv4-first render missing DISABLE_IPV6=true\n'
    fail_count=$((fail_count + 1))
  fi
  if [[ "${render}" != *'WG_HOST'* ]]; then
    printf '  [PASS] no legacy WG_HOST variable reaches the container\n'
    pass=$((pass + 1))
  else
    printf '  [FAIL] legacy WG_HOST still rendered into the container env\n'
    fail_count=$((fail_count + 1))
  fi
else
  printf '  [SKIP] docker daemon unavailable; render/lifecycle covered in CI\n'
fi

printf '\nRESULT: %s passed, %s failed\n' "${pass}" "${fail_count}"
(( fail_count == 0 ))
