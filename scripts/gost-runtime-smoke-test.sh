#!/usr/bin/env bash
# Execute the pinned GOST artifact and prove the exact TCP/UDP forwarding CLI
# used by the fixed-edge relay works against local echo targets.
#
# This is repository/runtime implementation evidence only. It does not prove
# the real client route is qualified.
# shellcheck shell=bash

set -euo pipefail

readonly GOST_VERSION="3.3.0"
readonly GOST_ARCHIVE="gost_${GOST_VERSION}_linux_amd64.tar.gz"
readonly GOST_ARCHIVE_SHA256="676fb7f78d267b6ae73df719c0c7f2b565dde7147da935cfafbc1e1da558b6d5"
readonly GOST_DOWNLOAD_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/${GOST_ARCHIVE}"
readonly UDP_SESSION_QUERY="keepalive=true&ttl=60s&readBufferSize=65535"

for cmd in curl sha256sum tar python3; do
  command -v "${cmd}" >/dev/null 2>&1 || { printf 'FAIL: %s is required\n' "${cmd}" >&2; exit 2; }
done

[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] || {
  printf 'FAIL: smoke test currently supports Linux x86_64 only\n' >&2
  exit 2
}

workdir="$(mktemp -d)"
echo_pid=""
gost_pid=""
cleanup() {
  if [[ -n "${gost_pid}" ]]; then
    kill "${gost_pid}" >/dev/null 2>&1 || true
    wait "${gost_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${echo_pid}" ]]; then
    kill "${echo_pid}" >/dev/null 2>&1 || true
    wait "${echo_pid}" >/dev/null 2>&1 || true
  fi
  rm -rf "${workdir}"
}
trap cleanup EXIT

archive="${workdir}/${GOST_ARCHIVE}"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
  --output "${archive}" "${GOST_DOWNLOAD_URL}"
printf '%s  %s\n' "${GOST_ARCHIVE_SHA256}" "${archive}" | sha256sum --check --status \
  || { printf 'FAIL: pinned GOST archive checksum mismatch\n' >&2; exit 1; }
tar -xzf "${archive}" -C "${workdir}"
gost="${workdir}/gost"
[[ -x "${gost}" ]] || { printf 'FAIL: GOST binary missing/not executable\n' >&2; exit 1; }

free_port() {
  local socket_type="$1"
  python3 - "${socket_type}" <<'PY'
import socket
import sys

kind = sys.argv[1]
type_ = socket.SOCK_STREAM if kind == "tcp" else socket.SOCK_DGRAM
with socket.socket(socket.AF_INET, type_) as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
}

target_tcp="$(free_port tcp)"
target_udp="$(free_port udp)"
relay_tcp="$(free_port tcp)"
relay_udp="$(free_port udp)"

python3 - "${target_tcp}" "${target_udp}" <<'PY' &
import select
import socket
import sys

tcp_port = int(sys.argv[1])
udp_port = int(sys.argv[2])

tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
tcp.bind(("127.0.0.1", tcp_port))
tcp.listen(16)

udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.bind(("127.0.0.1", udp_port))

while True:
    readable, _, _ = select.select([tcp, udp], [], [], 1.0)
    for sock in readable:
        if sock is tcp:
            conn, _ = tcp.accept()
            with conn:
                data = conn.recv(65535)
                if data:
                    conn.sendall(data)
        else:
            data, addr = udp.recvfrom(65535)
            if data:
                udp.sendto(data, addr)
PY
echo_pid=$!

"${gost}" \
  -L="tcp://127.0.0.1:${relay_tcp}/127.0.0.1:${target_tcp}" \
  -L="udp://127.0.0.1:${relay_udp}/127.0.0.1:${target_udp}?${UDP_SESSION_QUERY}" \
  >"${workdir}/gost.log" 2>&1 &
gost_pid=$!

ready=0
for ((attempt = 0; attempt < 50; attempt++)); do
  kill -0 "${echo_pid}" >/dev/null 2>&1 || { printf 'FAIL: echo target exited\n' >&2; exit 1; }
  kill -0 "${gost_pid}" >/dev/null 2>&1 || {
    cat "${workdir}/gost.log" >&2 || true
    printf 'FAIL: GOST exited before smoke traffic\n' >&2
    exit 1
  }
  if python3 - "${relay_tcp}" <<'PY' >/dev/null 2>&1
import socket
import sys

with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.2):
    pass
PY
  then
    ready=1
    break
  fi
  sleep 0.1
done

(( ready == 1 )) || {
  cat "${workdir}/gost.log" >&2 || true
  printf 'FAIL: GOST TCP listener did not become ready\n' >&2
  exit 1
}

python3 - "${relay_tcp}" "${relay_udp}" <<'PY'
import socket
import sys
import time

tcp_port = int(sys.argv[1])
udp_port = int(sys.argv[2])
marker = b"x-superplay-gost-runtime-smoke"

with socket.create_connection(("127.0.0.1", tcp_port), timeout=3) as s:
    s.sendall(marker)
    data = s.recv(65535)
    if data != marker:
        raise SystemExit(f"TCP echo mismatch: {data!r}")

last_error = None
for _ in range(10):
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(0.5)
            s.sendto(marker, ("127.0.0.1", udp_port))
            data, _ = s.recvfrom(65535)
            if data != marker:
                raise RuntimeError(f"UDP echo mismatch: {data!r}")
            break
    except Exception as exc:
        last_error = exc
        time.sleep(0.1)
else:
    raise SystemExit(f"UDP forwarding never became ready: {last_error}")
PY

printf 'gost_version=%s\n' "${GOST_VERSION}"
printf 'tcp_forward=PASS\n'
printf 'udp_forward=PASS\n'
printf 'udp_session_policy=%s\n' "${UDP_SESSION_QUERY}"
printf 'RESULT=PASS\n'
