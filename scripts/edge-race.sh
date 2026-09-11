#!/usr/bin/env bash
# Compare multiple candidate edge nodes using the repository's authoritative
# bidirectional iperf3 gate. The weaker single-stream direction controls ranking.
#
# Run from Linux/WSL with WireGuard OFF after each candidate temporarily exposes
# iperf3/TCP 5201 to the client source IP.
#
# Usage:
#   bash scripts/edge-race.sh label=host [label=host ...]
#
# Optional environment variables:
#   EDGE_QUALIFY_PORT=5201
#   EDGE_QUALIFY_SECONDS=15
#   EDGE_PATH_MIN_TCP_MBPS=5
#   EDGE_PATH_REJECT_TCP_MBPS=1
#
# Exit codes:
#   0 = at least one QUALIFIED candidate; SELECTED_* is printed
#   3 = no QUALIFIED candidate, but at least one DEGRADED candidate
#   4 = all measured candidates are REJECT_NODE
#   1 = only measurement errors occurred
#   2 = invalid usage
# shellcheck shell=bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
qualifier="${script_dir}/edge-qualify.sh"
port="${EDGE_QUALIFY_PORT:-5201}"
seconds="${EDGE_QUALIFY_SECONDS:-15}"
min_mbps="${EDGE_PATH_MIN_TCP_MBPS:-5}"
reject_mbps="${EDGE_PATH_REJECT_TCP_MBPS:-1}"

(( $# >= 1 )) || {
  printf 'Usage: %s label=host [label=host ...]\n' "$0" >&2
  exit 2
}

[[ -x "${qualifier}" || -f "${qualifier}" ]] || {
  printf 'ERROR: missing %s\n' "${qualifier}" >&2
  exit 2
}

command -v awk >/dev/null 2>&1 || { printf 'ERROR: awk is required\n' >&2; exit 2; }
command -v sort >/dev/null 2>&1 || { printf 'ERROR: sort is required\n' >&2; exit 2; }

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
results_tsv="${workdir}/results.tsv"
: >"${results_tsv}"

printf 'X-SuperPlay Global Edge - candidate race\n'
printf 'qualification_port=%s\n' "${port}"
printf 'qualification_seconds=%s\n' "${seconds}"
printf 'qualified_min_mbps=%s\n' "${min_mbps}"
printf 'reject_below_mbps=%s\n' "${reject_mbps}"
printf 'ranking_rule=weaker_single_stream_direction\n\n'

for candidate in "$@"; do
  label="${candidate%%=*}"
  host="${candidate#*=}"

  if [[ "${candidate}" != *=* || -z "${label}" || -z "${host}" ]]; then
    printf 'ERROR: candidate must be label=host, got: %s\n' "${candidate}" >&2
    exit 2
  fi

  printf '=== candidate=%s host=%s ===\n' "${label}" "${host}"

  set +e
  output="$(bash "${qualifier}" "${host}" "${port}" "${seconds}" "${min_mbps}" "${reject_mbps}" 2>&1)"
  rc=$?
  set -e

  printf '%s\n' "${output}"

  result="$(printf '%s\n' "${output}" | awk -F= '$1=="RESULT"{v=$2} END{print v}')"
  fwd="$(printf '%s\n' "${output}" | awk -F= '$1=="forward_single_mbps"{print $2; exit}')"
  rev="$(printf '%s\n' "${output}" | awk -F= '$1=="reverse_single_mbps"{print $2; exit}')"

  if [[ -z "${result}" || -z "${fwd}" || -z "${rev}" ]]; then
    result="ERROR"
    fwd="${fwd:-0.000}"
    rev="${rev:-0.000}"
    weaker="0.000"
  else
    weaker="$(awk -v a="${fwd}" -v b="${rev}" 'BEGIN{printf "%.3f", (a < b ? a : b)}')"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${label}" "${host}" "${result}" "${fwd}" "${rev}" "${weaker}" "${rc}" \
    >>"${results_tsv}"
  printf 'candidate_weaker_single_mbps=%s\n\n' "${weaker}"
done

printf '%-18s %-18s %-12s %12s %12s %12s\n' \
  'LABEL' 'HOST' 'RESULT' 'UP_Mbps' 'DOWN_Mbps' 'WEAKER_Mbps'
printf '%-18s %-18s %-12s %12s %12s %12s\n' \
  '------------------' '------------------' '------------' '------------' '------------' '------------'

sort -t $'\t' -k6,6nr "${results_tsv}" | while IFS=$'\t' read -r label host result fwd rev weaker rc; do
  printf '%-18s %-18s %-12s %12s %12s %12s\n' \
    "${label}" "${host}" "${result}" "${fwd}" "${rev}" "${weaker}"
done

selected_line="$(awk -F'\t' '$3=="QUALIFIED"{print}' "${results_tsv}" | sort -t $'\t' -k6,6nr | head -n1 || true)"
if [[ -n "${selected_line}" ]]; then
  IFS=$'\t' read -r selected_label selected_host _ _ _ selected_weaker _ <<<"${selected_line}"
  printf '\nSELECTED_EDGE=%s\n' "${selected_label}"
  printf 'SELECTED_HOST=%s\n' "${selected_host}"
  printf 'SELECTED_WEAKER_SINGLE_MBPS=%s\n' "${selected_weaker}"
  printf 'RESULT=QUALIFIED\n'
  exit 0
fi

if awk -F'\t' '$3=="DEGRADED"{found=1} END{exit found?0:1}' "${results_tsv}"; then
  printf '\nSELECTED_EDGE=NONE\n'
  printf 'RESULT=DEGRADED\n'
  printf 'ACTION=compare_more_regions_or_providers\n'
  exit 3
fi

if awk -F'\t' '$3=="REJECT_NODE"{found=1} END{exit found?0:1}' "${results_tsv}"; then
  printf '\nSELECTED_EDGE=NONE\n'
  printf 'RESULT=REJECT_NODE\n'
  printf 'ACTION=replace_route_or_provider_do_not_tune_rejected_node\n'
  exit 4
fi

printf '\nSELECTED_EDGE=NONE\n'
printf 'RESULT=ERROR\n'
exit 1
