#!/usr/bin/env bash
# Diagnose a fixed edge from Linux/WSL with WireGuard OFF.
# Measures TCP single/parallel and UDP loss in both directions and emits an
# evidence-driven recovery action without changing the edge region.
# Usage: bash scripts/edge-path-diagnose.sh <server> [port] [seconds]
# shellcheck shell=bash

set -euo pipefail

server="${1:-}"
port="${2:-5201}"
seconds="${3:-15}"
tcp_good="${EDGE_PATH_MIN_TCP_MBPS:-5}"
tcp_reject="${EDGE_PATH_REJECT_TCP_MBPS:-1}"
udp_rate="${EDGE_PATH_UDP_TEST_MBPS:-3}"
udp_loss_max="${EDGE_PATH_UDP_MAX_LOSS_PCT:-5}"

[[ -n "${server}" ]] || { printf 'Usage: %s <server> [port] [seconds]\n' "$0" >&2; exit 2; }
command -v iperf3 >/dev/null 2>&1 || { printf 'ERROR: iperf3 required\n' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'ERROR: python3 required\n' >&2; exit 2; }

parse_tcp() {
  python3 -c '
import json, sys
obj=json.load(sys.stdin)
end=obj.get("end", {})
for key in ("sum_received", "sum", "sum_sent"):
    value=end.get(key)
    if isinstance(value, dict) and value.get("bits_per_second") is not None:
        print("{:.3f}".format(float(value["bits_per_second"])/1_000_000))
        raise SystemExit(0)
print("0.000")
'
}

parse_udp() {
  python3 -c '
import json, sys
obj=json.load(sys.stdin)
end=obj.get("end", {})
for key in ("sum", "sum_received", "sum_sent"):
    value=end.get(key)
    if isinstance(value, dict) and value.get("lost_percent") is not None:
        mbps=float(value.get("bits_per_second") or 0)/1_000_000
        loss=float(value.get("lost_percent") or 0)
        jitter=float(value.get("jitter_ms") or 0)
        print("{:.3f}|{:.3f}|{:.3f}".format(mbps, loss, jitter))
        raise SystemExit(0)
print("0.000|100.000|0.000")
'
}

run_tcp() {
  local reverse="$1" parallel="$2"
  local args=(-J -c "${server}" -p "${port}" -t "${seconds}")
  [[ "${reverse}" == "yes" ]] && args+=(-R)
  (( parallel > 1 )) && args+=(-P "${parallel}")
  iperf3 "${args[@]}" 2>/dev/null | parse_tcp
}

run_udp() {
  local reverse="$1"
  local args=(-J -u -b "${udp_rate}M" -c "${server}" -p "${port}" -t "${seconds}")
  [[ "${reverse}" == "yes" ]] && args+=(-R)
  iperf3 "${args[@]}" 2>/dev/null | parse_udp
}

ping_avg="unavailable"
if command -v ping >/dev/null 2>&1; then
  out="$(ping -4 -c 5 -W 2 "${server}" 2>/dev/null || true)"
  value="$(printf '%s\n' "${out}" | awk -F'=' '/min\/avg\/max/{gsub(/ /,"",$2); split($2,a,"/"); print a[2]; exit}')"
  if [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    ping_avg="${value}"
  fi
fi

printf 'X-SuperPlay Global Edge - fixed-edge path diagnosis\n'
printf 'server=%s\n' "${server}"
printf 'icmp_avg_ms=%s\n' "${ping_avg}"
printf 'tcp_qualified_min_mbps=%s\n' "${tcp_good}"
printf 'tcp_reject_below_mbps=%s\n' "${tcp_reject}"
printf 'udp_test_rate_mbps=%s\n' "${udp_rate}"
printf 'udp_max_loss_pct=%s\n' "${udp_loss_max}"

client_to_edge_single="$(run_tcp no 1 || printf '0.000\n')"
edge_to_client_single="$(run_tcp yes 1 || printf '0.000\n')"
client_to_edge_parallel="$(run_tcp no 4 || printf '0.000\n')"
edge_to_client_parallel="$(run_tcp yes 4 || printf '0.000\n')"
client_to_edge_udp="$(run_udp no || printf '0.000|100.000|0.000\n')"
edge_to_client_udp="$(run_udp yes || printf '0.000|100.000|0.000\n')"

IFS='|' read -r client_to_edge_udp_mbps client_to_edge_udp_loss client_to_edge_udp_jitter <<<"${client_to_edge_udp}"
IFS='|' read -r edge_to_client_udp_mbps edge_to_client_udp_loss edge_to_client_udp_jitter <<<"${edge_to_client_udp}"

printf 'tcp_client_to_edge_single_mbps=%s\n' "${client_to_edge_single}"
printf 'tcp_edge_to_client_single_mbps=%s\n' "${edge_to_client_single}"
printf 'tcp_client_to_edge_parallel4_mbps=%s\n' "${client_to_edge_parallel}"
printf 'tcp_edge_to_client_parallel4_mbps=%s\n' "${edge_to_client_parallel}"
printf 'udp_client_to_edge_mbps=%s\n' "${client_to_edge_udp_mbps}"
printf 'udp_client_to_edge_loss_pct=%s\n' "${client_to_edge_udp_loss}"
printf 'udp_client_to_edge_jitter_ms=%s\n' "${client_to_edge_udp_jitter}"
printf 'udp_edge_to_client_mbps=%s\n' "${edge_to_client_udp_mbps}"
printf 'udp_edge_to_client_loss_pct=%s\n' "${edge_to_client_udp_loss}"
printf 'udp_edge_to_client_jitter_ms=%s\n' "${edge_to_client_udp_jitter}"

read -r classification action < <(python3 - \
  "${client_to_edge_single}" "${edge_to_client_single}" \
  "${client_to_edge_parallel}" "${edge_to_client_parallel}" \
  "${client_to_edge_udp_loss}" "${edge_to_client_udp_loss}" \
  "${tcp_good}" "${tcp_reject}" "${udp_loss_max}" <<'PY'
import sys
up, down, up4, down4, udp_up_loss, udp_down_loss, good, reject, max_loss = map(float, sys.argv[1:])
weak = min(up, down)
weak4 = min(up4, down4)
udp_bad = max(udp_up_loss, udp_down_loss) > max_loss
if weak >= good:
    if udp_bad:
        print("TCP_OK_UDP_BAD GAAP_UDP_OR_WSTUNNEL_AB_TEST")
    else:
        print("BASE_PATH_QUALIFIED KEEP_NATIVE_WG_AND_FIX_MTU_MSS")
elif weak < reject:
    if weak4 >= good:
        print("SINGLE_FLOW_COLLAPSE GAAP_ACCELERATION_AB_TEST")
    else:
        print("BASE_PATH_SEVERE GAAP_CROSS_BORDER_ACCELERATION_PRIMARY")
else:
    if weak4 >= good:
        print("SINGLE_FLOW_DEGRADED GAAP_ACCELERATION_AB_TEST")
    else:
        print("BASE_PATH_DEGRADED ROUTE_TRACE_THEN_GAAP_AB_TEST")
PY
)

printf 'CLASSIFICATION=%s\n' "${classification}"
printf 'ACTION=%s\n' "${action}"

if command -v nexttrace >/dev/null 2>&1; then
  printf 'TRACE_TCP_443_BEGIN\n'
  nexttrace --tcp --port 443 --queries 2 --parallel-requests 1 --no-color "${server}" || true
  printf 'TRACE_TCP_443_END\n'
  printf 'TRACE_UDP_51820_BEGIN\n'
  nexttrace --udp --port 51820 --queries 2 --parallel-requests 1 --no-color "${server}" || true
  printf 'TRACE_UDP_51820_END\n'
else
  printf 'NEXTTRACE=unavailable\n'
fi

[[ "${classification}" == "BASE_PATH_QUALIFIED" ]] && exit 0
exit 3
