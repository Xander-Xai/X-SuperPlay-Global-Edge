#!/usr/bin/env bash
# Build a fixed-edge ingress relay without changing the configured origin.
#
# The relay receives WireGuard UDP near the client and forwards it to the
# configured origin. Qualification mode additionally forwards iperf3 TCP+UDP so
# the exact relay path can be A/B tested before production endpoint promotion.
#
# Usage:
#   bash scripts/gost-ingress-relay.sh --render <origin> [wg_port] [iperf_port] <qualification|production>
#   sudo bash scripts/gost-ingress-relay.sh --apply <origin> [wg_port] [iperf_port] <qualification|production>
#   sudo bash scripts/gost-ingress-relay.sh --check <origin> [wg_port] [iperf_port] <qualification|production>
#
# This script intentionally does NOT change cloud/host firewalls. During
# qualification, TCP+UDP iperf3 port access must be restricted to the real
# client source IP where practical. After qualification, re-apply production
# mode so the temporary iperf3 forwarders disappear.
# shellcheck shell=bash

set -euo pipefail

readonly GOST_VERSION="3.3.0"
readonly GOST_ARCHIVE="gost_${GOST_VERSION}_linux_amd64.tar.gz"
readonly GOST_ARCHIVE_SHA256="676fb7f78d267b6ae73df719c0c7f2b565dde7147da935cfafbc1e1da558b6d5"
readonly GOST_DOWNLOAD_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/${GOST_ARCHIVE}"
readonly INSTALL_PATH="/usr/local/bin/gost"
readonly UNIT_PATH="/etc/systemd/system/x-superplay-gost-ingress.service"
readonly UNIT_NAME="x-superplay-gost-ingress.service"
readonly UDP_SESSION_QUERY="keepalive=true&ttl=60s&readBufferSize=65535"

usage() {
  cat >&2 <<'EOF'
Usage:
  gost-ingress-relay.sh --render <origin> [wg_port] [iperf_port] <qualification|production>
  gost-ingress-relay.sh --apply  <origin> [wg_port] [iperf_port] <qualification|production>
  gost-ingress-relay.sh --check  <origin> [wg_port] [iperf_port] <qualification|production>

Examples:
  bash scripts/gost-ingress-relay.sh --render 203.0.113.10 51820 5201 qualification
  sudo bash scripts/gost-ingress-relay.sh --apply 203.0.113.10 51820 5201 qualification
  sudo bash scripts/gost-ingress-relay.sh --apply 203.0.113.10 51820 5201 production
EOF
}

require_uint_port() {
  local value="$1" name="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || { printf 'ERROR: %s must be numeric\n' "${name}" >&2; exit 2; }
  (( value >= 1 && value <= 65535 )) || { printf 'ERROR: %s out of range\n' "${name}" >&2; exit 2; }
}

mode="${1:-}"
origin="${2:-}"
wg_port="${3:-51820}"
iperf_port="${4:-5201}"
profile="${5:-}"

case "${mode}" in
  --render|--apply|--check) ;;
  *) usage; exit 2 ;;
esac
[[ -n "${origin}" ]] || { usage; exit 2; }
case "${profile}" in
  qualification|production) ;;
  *) printf 'ERROR: profile must be qualification or production\n' >&2; usage; exit 2 ;;
esac
require_uint_port "${wg_port}" "wg_port"
require_uint_port "${iperf_port}" "iperf_port"
[[ "${wg_port}" != "${iperf_port}" ]] || { printf 'ERROR: WireGuard and iperf3 ports must differ\n' >&2; exit 2; }

render_unit() {
  local exec_start
  # WireGuard is a long-lived bidirectional UDP workload. GOST's UDP listener
  # defaults keepAlive=false, so make the session policy explicit rather than
  # relying on one-response connection teardown semantics. A 60s idle TTL is
  # long enough for normal WireGuard keepalives/rekeys while still bounding
  # stale relay state. The enlarged read buffer avoids truncating valid UDP
  # datagrams during qualification or production forwarding.
  exec_start="${INSTALL_PATH} -L=udp://:${wg_port}/${origin}:${wg_port}?${UDP_SESSION_QUERY}"
  if [[ "${profile}" == "qualification" ]]; then
    exec_start+=" -L=tcp://:${iperf_port}/${origin}:${iperf_port}"
    exec_start+=" -L=udp://:${iperf_port}/${origin}:${iperf_port}?${UDP_SESSION_QUERY}"
  fi

  cat <<EOF
[Unit]
Description=X-SuperPlay fixed-edge GOST ingress relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${exec_start}
Restart=always
RestartSec=2s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
}

if [[ "${mode}" == "--render" ]]; then
  render_unit
  exit 0
fi

(( EUID == 0 )) || { printf 'ERROR: %s requires root\n' "${mode}" >&2; exit 2; }
command -v systemctl >/dev/null 2>&1 || { printf 'ERROR: systemctl required\n' >&2; exit 2; }

install_gost() {
  if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
    printf 'ERROR: pinned installer currently supports Linux x86_64 only\n' >&2
    exit 2
  fi
  command -v curl >/dev/null 2>&1 || { printf 'ERROR: curl required\n' >&2; exit 2; }
  command -v sha256sum >/dev/null 2>&1 || { printf 'ERROR: sha256sum required\n' >&2; exit 2; }
  command -v tar >/dev/null 2>&1 || { printf 'ERROR: tar required\n' >&2; exit 2; }

  local tmp archive
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  archive="${tmp}/${GOST_ARCHIVE}"
  curl --fail --location --proto '=https' --tlsv1.2 --output "${archive}" "${GOST_DOWNLOAD_URL}"
  printf '%s  %s\n' "${GOST_ARCHIVE_SHA256}" "${archive}" | sha256sum --check --status \
    || { printf 'ERROR: GOST archive checksum mismatch\n' >&2; exit 1; }
  tar -xzf "${archive}" -C "${tmp}"
  [[ -f "${tmp}/gost" ]] || { printf 'ERROR: GOST binary missing from archive\n' >&2; exit 1; }
  install -m 0755 "${tmp}/gost" "${INSTALL_PATH}"
  trap - RETURN
  rm -rf "${tmp}"
}

check_state() {
  local wg_forward
  wg_forward="udp://:${wg_port}/${origin}:${wg_port}?${UDP_SESSION_QUERY}"

  [[ -x "${INSTALL_PATH}" ]] || { printf 'STATE=FAIL\nreason=gost_not_installed\n'; return 1; }
  systemctl is-active --quiet "${UNIT_NAME}" || { printf 'STATE=FAIL\nreason=service_not_active\n'; return 1; }
  grep -Fq "${wg_forward}" "${UNIT_PATH}" \
    || { printf 'STATE=FAIL\nreason=wireguard_forward_or_udp_session_policy_mismatch\n'; return 1; }

  if [[ "${profile}" == "qualification" ]]; then
    grep -Fq "tcp://:${iperf_port}/${origin}:${iperf_port}" "${UNIT_PATH}" \
      || { printf 'STATE=FAIL\nreason=iperf_tcp_forward_missing\n'; return 1; }
    grep -Fq "udp://:${iperf_port}/${origin}:${iperf_port}?${UDP_SESSION_QUERY}" "${UNIT_PATH}" \
      || { printf 'STATE=FAIL\nreason=iperf_udp_forward_or_session_policy_missing\n'; return 1; }
  else
    if grep -Fq ":${iperf_port}/${origin}:${iperf_port}" "${UNIT_PATH}"; then
      printf 'STATE=FAIL\nreason=temporary_iperf_forward_present_in_production\n'
      return 1
    fi
  fi

  printf 'STATE=PASS\n'
  printf 'profile=%s\n' "${profile}"
  printf 'origin=%s\n' "${origin}"
  printf 'wireguard_forward=udp:%s->%s:%s\n' "${wg_port}" "${origin}" "${wg_port}"
  printf 'udp_keepalive=yes\n'
  printf 'udp_idle_ttl_s=60\n'
  printf 'udp_read_buffer_bytes=65535\n'
  if [[ "${profile}" == "qualification" ]]; then
    printf 'iperf_forward=tcp+udp:%s->%s:%s\n' "${iperf_port}" "${origin}" "${iperf_port}"
  else
    printf 'iperf_forward=disabled\n'
  fi
}

if [[ "${mode}" == "--check" ]]; then
  check_state
  exit $?
fi

install_gost
render_unit >"${UNIT_PATH}.tmp"
chmod 0644 "${UNIT_PATH}.tmp"
mv "${UNIT_PATH}.tmp" "${UNIT_PATH}"
systemctl daemon-reload
systemctl enable --now "${UNIT_NAME}"
systemctl restart "${UNIT_NAME}"
check_state

printf 'ACTION_NEXT='
if [[ "${profile}" == "qualification" ]]; then
  printf 'restrict_iperf_firewall_then_run_bidirectional_path_diagnosis\n'
else
  printf 'set_WireGuard_endpoint_to_relay_only_after_qualified_AB_evidence\n'
fi
