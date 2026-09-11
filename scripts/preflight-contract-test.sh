#!/usr/bin/env bash
# Regression contract for production fail-closed port probing.
# shellcheck shell=bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "${tmpdir}"; }
trap cleanup EXIT

prod_env="${tmpdir}/production.env"
cp .env.example "${prod_env}"
sed -i 's/^EDGE_ENV=.*/EDGE_ENV=production/' "${prod_env}"
sed -i 's/^EDGE_PUBLIC_HOST=.*/EDGE_PUBLIC_HOST=203.0.113.10/' "${prod_env}"

# Export shell functions named like the normal listener probes. `command -v ss`
# still resolves them, but the actual probe fails, forcing edge_port_used to
# return its documented rc=2 (cannot determine). This exercises preflight's
# policy without changing the host or uninstalling iproute2/net-tools.
ss() { return 127; }
netstat() { return 127; }
export -f ss netstat

local_out="${tmpdir}/local.out"
local_rc=0
bash scripts/preflight.sh .env.example >"${local_out}" 2>&1 || local_rc=$?

grep -Fq '[WARN] Cannot verify WireGuard UDP port 51820 availability (no usable ss/netstat probe).' "${local_out}"
grep -Fq '[WARN] Cannot verify admin TCP port 51821 availability (no usable ss/netstat probe).' "${local_out}"
if grep -Fq '[FAIL] WireGuard UDP port 51820 availability verifiable' "${local_out}"; then
  echo 'FAIL: local/CI preflight must keep unknown port probing advisory.' >&2
  cat "${local_out}" >&2
  exit 1
fi
printf 'PASS: local/CI unknown port probe remains WARN (preflight rc=%s may reflect unrelated host checks)\n' "${local_rc}"

prod_out="${tmpdir}/production.out"
prod_rc=0
bash scripts/preflight.sh "${prod_env}" >"${prod_out}" 2>&1 || prod_rc=$?

if [[ "${prod_rc}" -eq 0 ]]; then
  echo 'FAIL: production preflight passed when port availability could not be determined.' >&2
  cat "${prod_out}" >&2
  exit 1
fi

grep -Fq '[FAIL] WireGuard UDP port 51820 availability verifiable' "${prod_out}"
grep -Fq '[FAIL] Admin TCP port 51821 availability verifiable' "${prod_out}"
grep -Fq 'Install iproute2 (ss) or net-tools (netstat), then re-run preflight.' "${prod_out}"
grep -Fq 'RESULT: FAIL' "${prod_out}"
printf 'PASS: production unknown port probe is fail-closed (rc=%s)\n' "${prod_rc}"
