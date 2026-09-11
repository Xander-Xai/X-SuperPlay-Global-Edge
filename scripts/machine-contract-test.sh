#!/usr/bin/env bash
# Regression test for scripts/wireguard-check.sh stdout ordering and freshness.
# The public machine contract requires STATE=... to be the first stdout line.
# shellcheck shell=bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

cat > "${tmp}/mock-wg" <<'MOCK'
#!/usr/bin/env bash
key="$*"
if [[ -f "${EDGE_WG_FIXTURE}/${key}.out" ]]; then
  cat "${EDGE_WG_FIXTURE}/${key}.out"
  exit 0
fi
if [[ -f "${EDGE_WG_FIXTURE}/${key}.fail" ]]; then
  exit 1
fi
exit 0
MOCK
chmod +x "${tmp}/mock-wg"

make_ready() { # <dir> <port> <handshake:none|fresh|stale>
  local dir="$1" port="$2" handshake="$3" ts=0
  mkdir -p "${dir}"
  printf 'wg0\n' > "${dir}/show interfaces.out"
  printf '%s\n' "${port}" > "${dir}/show wg0 listen-port.out"
  printf 'PeerKey==\n' > "${dir}/show wg0 peers.out"
  case "${handshake}" in
    fresh) ts="$(date +%s)" ;;
    stale) ts="$(( $(date +%s) - 3600 ))" ;;
    none) ts=0 ;;
    *) printf 'invalid fixture handshake mode: %s\n' "${handshake}" >&2; exit 1 ;;
  esac
  printf 'PeerKey==\t%s\n' "${ts}" > "${dir}/show wg0 latest-handshakes.out"
}

assert_first_state() { # <name> <fixture> <expected-state> <expected-rc> [expected-substring]
  local name="$1" fixture="$2" expected="$3" expected_rc="$4" expected_sub="${5:-}"
  local out rc=0 first
  out="$(env EDGE_WG_MOCK_BIN="${tmp}/mock-wg" EDGE_WG_FIXTURE="${fixture}" \
    bash scripts/wireguard-check.sh .env.example 2>/dev/null)" || rc=$?
  first="$(printf '%s\n' "${out}" | head -n1)"
  if [[ "${rc}" != "${expected_rc}" || "${first}" != "STATE=${expected}" ]]; then
    printf 'FAIL: %s expected rc=%s first=STATE=%s, got rc=%s first=%q\n' \
      "${name}" "${expected_rc}" "${expected}" "${rc}" "${first}" >&2
    printf '%s\n' "${out}" >&2
    exit 1
  fi
  if [[ -n "${expected_sub}" && "${out}" != *"${expected_sub}"* ]]; then
    printf 'FAIL: %s expected output containing %q\n%s\n' "${name}" "${expected_sub}" "${out}" >&2
    exit 1
  fi
  printf 'PASS: %s -> %s\n' "${name}" "${first}"
}

mkdir -p "${tmp}/not-configured"
assert_first_state "not configured" "${tmp}/not-configured" "NOT_CONFIGURED" 2 'handshake_fresh=no'

make_ready "${tmp}/ready" 51820 none
assert_first_state "configured without handshake" "${tmp}/ready" "READY_NO_HANDSHAKE" 0 'handshake_fresh=no'

make_ready "${tmp}/handshake" 51820 fresh
assert_first_state "configured with fresh handshake" "${tmp}/handshake" "HANDSHAKE_OK" 0 'handshake_fresh=yes'

make_ready "${tmp}/stale" 51820 stale
assert_first_state "stale historical handshake is not current evidence" "${tmp}/stale" "READY_NO_HANDSHAKE" 0 'handshake_fresh=no'

make_ready "${tmp}/mismatch" 51821 none
assert_first_state "listen-port mismatch" "${tmp}/mismatch" "MISMATCH" 1

printf 'PASS: wireguard-check STATE-first + handshake-freshness contract is stable\n'
