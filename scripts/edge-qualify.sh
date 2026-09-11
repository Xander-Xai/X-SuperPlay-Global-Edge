#!/usr/bin/env bash
# Client-side edge-node qualification using iperf3 JSON output.
# Run from a Linux client/WSL with WireGuard OFF against a temporary iperf3
# server on the candidate edge node.
# Usage:
#   bash scripts/edge-qualify.sh <server> [port] [seconds] [min_mbps] [reject_mbps]
#
# RESULT semantics are throughput hard gates. ICMP RTT is recorded as supporting
# path-quality evidence when the candidate/provider permits ICMP; unavailable
# ICMP never substitutes for the bidirectional iperf3 measurements.
#
#   QUALIFIED   both single-stream directions >= min_mbps
#   DEGRADED    below min_mbps but both directions >= reject_mbps
#   REJECT_NODE either single-stream direction < reject_mbps
# shellcheck shell=bash

set -euo pipefail

server="${1:-}"
port="${2:-5201}"
seconds="${3:-15}"
min_mbps="${4:-5}"
reject_mbps="${5:-1}"

[[ -n "${server}" ]] || { printf 'Usage: %s <server> [port] [seconds] [min_mbps] [reject_mbps]\n' "$0" >&2; exit 2; }
if ! [[ "${port}" =~ ^[0-9]+$ ]] || ! (( port >= 1 && port <= 65535 )); then
  printf 'ERROR: invalid port\n' >&2
  exit 2
fi
if ! [[ "${seconds}" =~ ^[0-9]+$ ]] || ! (( seconds >= 5 && seconds <= 120 )); then
  printf 'ERROR: seconds must be 5..120\n' >&2
  exit 2
fi
[[ "${min_mbps}" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf 'ERROR: min_mbps must be numeric\n' >&2; exit 2; }
[[ "${reject_mbps}" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf 'ERROR: reject_mbps must be numeric\n' >&2; exit 2; }

command -v iperf3 >/dev/null 2>&1 || { printf 'ERROR: iperf3 is required on the client\n' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'ERROR: python3 is required on the client\n' >&2; exit 2; }

extract_mbps() {
  python3 -c '
import json, sys
obj=json.load(sys.stdin)
end=obj.get("end", {})
for key in ("sum_received", "sum", "sum_sent"):
    item=end.get(key)
    if isinstance(item, dict) and item.get("bits_per_second") is not None:
        print("{:.3f}".format(float(item["bits_per_second"])/1_000_000))
        raise SystemExit(0)
print("0.000")
'
}

run_test() {
  local reverse="$1" parallel="$2"
  local args=(-J -c "${server}" -p "${port}" -t "${seconds}")
  [[ "${reverse}" == "yes" ]] && args+=(-R)
  (( parallel > 1 )) && args+=(-P "${parallel}")
  iperf3 "${args[@]}" 2>/dev/null | extract_mbps
}

measure_icmp_avg_ms() {
  command -v ping >/dev/null 2>&1 || { printf 'unavailable\n'; return 0; }
  local out avg
  out="$(ping -4 -c 5 -W 2 "${server}" 2>/dev/null || true)"
  avg="$(printf '%s\n' "${out}" | awk -F'=' '/min\/avg\/max/{gsub(/ /,"",$2); split($2,a,"/"); print a[2]; exit}')"
  if [[ "${avg}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s\n' "${avg}"
  else
    printf 'unavailable\n'
  fi
}

printf 'X-SuperPlay Global Edge - edge qualification\n'
printf 'server=%s\n' "${server}"
printf 'port=%s\n' "${port}"
printf 'seconds=%s\n' "${seconds}"
printf 'qualified_min_mbps=%s\n' "${min_mbps}"
printf 'reject_below_mbps=%s\n' "${reject_mbps}"

icmp_avg_ms="$(measure_icmp_avg_ms)"
forward_single="$(run_test no 1)" || { printf 'RESULT=ERROR\n' >&2; exit 1; }
reverse_single="$(run_test yes 1)" || { printf 'RESULT=ERROR\n' >&2; exit 1; }
forward_parallel="$(run_test no 4)" || { printf 'RESULT=ERROR\n' >&2; exit 1; }
reverse_parallel="$(run_test yes 4)" || { printf 'RESULT=ERROR\n' >&2; exit 1; }

printf 'icmp_avg_ms=%s\n' "${icmp_avg_ms}"
printf 'forward_single_mbps=%s\n' "${forward_single}"
printf 'reverse_single_mbps=%s\n' "${reverse_single}"
printf 'forward_parallel4_mbps=%s\n' "${forward_parallel}"
printf 'reverse_parallel4_mbps=%s\n' "${reverse_parallel}"

result="$(python3 - "${forward_single}" "${reverse_single}" "${min_mbps}" "${reject_mbps}" <<'PY'
import sys
fwd, rev, good, reject = map(float, sys.argv[1:])
if fwd >= good and rev >= good:
    print("QUALIFIED")
elif fwd < reject or rev < reject:
    print("REJECT_NODE")
else:
    print("DEGRADED")
PY
)"

printf 'RESULT=%s\n' "${result}"
[[ "${result}" == "QUALIFIED" ]] && exit 0
[[ "${result}" == "DEGRADED" ]] && exit 3
exit 4
