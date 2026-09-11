# Optional wstunnel Fallback Profile

This document defines the **P1 restrictive-network fallback** for X-SuperPlay
Global Edge. It preserves native WireGuard/UDP as the primary transport and
adds an explicit WireGuard-over-WSS/TCP-443 profile for networks where native
UDP is blocked or materially degraded.

It is **not** a fix for a bad client-to-edge base route. A candidate edge must
first pass the repository edge-qualification gate (`QUALIFIED`, or an
explicitly reviewed `DEGRADED` retest decision). `REJECT_NODE` blocks this
profile as well as native WireGuard promotion.

## Upstream identity

Reviewed upstream project:

```text
repository: erebe/wstunnel
release:    v10.7.1
published:  2026-09-01
release:    immutable (GitHub release metadata)
```

Pinned release-asset checksums used by this design:

```text
linux_amd64:
  wstunnel_10.7.1_linux_amd64.tar.gz
  sha256=fa842ed53fbb14b1c69cd98829f9895d7f8a6b0d562c57c1175851a52cea9ea2

linux_arm64:
  wstunnel_10.7.1_linux_arm64.tar.gz
  sha256=99f9506d01d1b4073254609600ec5056dab8dc58aec75c32f6eb0508335a8fd2

windows_amd64:
  wstunnel_10.7.1_windows_amd64.tar.gz
  sha256=deb3c8b8d9fecf5428f7e0caabbc13aeb3b1edbfba49e1724a7a065c027bd0f2

android_arm64:
  wstunnel_10.7.1_android_arm64.tar.gz
  sha256=7d4f719e8f06d48aa1f22daf2bb1d47890d5eec8166f0d22a2ea827edb90e6ab
```

Do not use `latest` or an unverified binary in production. A future automated
installer must download an exact version and verify the matching SHA-256 before
installation.

## Architecture

### Native profile — default

```text
Windows / Android
      |
      | WireGuard UDP 51820
      v
edge:51820/udp -> wg-easy -> Internet
```

Nothing in the fallback design changes this default path.

### Restrictive-network fallback — explicit opt-in

```text
WireGuard client
Endpoint = 127.0.0.1:51820
MTU      = recovery baseline (start at 1280, revalidate for extra encapsulation)
      |
      | UDP on loopback only
      v
wstunnel client
-L udp://127.0.0.1:51820:127.0.0.1:51820?timeout_sec=0
      |
      | WebSocket over TLS / TCP 443
      v
edge wstunnel server
      |
      | restricted UDP destination
      v
127.0.0.1:51820/udp (Docker-published wg-easy WireGuard port)
      |
      v
wg-easy -> Internet
```

The upstream wstunnel WireGuard example uses the same model: the local
wstunnel client listens on UDP 51820, the WireGuard peer endpoint becomes
`localhost:51820`, and the UDP tunnel timeout is disabled with
`timeout_sec=0`.

## Server safety contract

The fallback server is deliberately **not enabled by default**.

Before enabling it on a production edge:

1. the node must not be `REJECT_NODE`;
2. TCP/443 must be deliberately opened in the cloud firewall;
3. use a reviewed DNS hostname for the WSS endpoint;
4. use a real TLS certificate/key stored outside Git and outside command logs;
5. restrict wstunnel forwarding to the WireGuard listener only;
6. preserve wg-easy admin UI loopback-only on `127.0.0.1:51821`;
7. do not expose a generic SOCKS/HTTP/dynamic forwarding endpoint;
8. native WireGuard UDP 51820 remains available as the default profile.

Target server command shape (operator values intentionally omitted):

```bash
wstunnel server \
  --restrict-to '127.0.0.1:51820' \
  --tls-certificate /path/outside/repo/server-cert.pem \
  --tls-private-key /path/outside/repo/server-key.pem \
  wss://0.0.0.0:443
```

The TLS private key must never be committed, pasted into issue/PR logs, or
placed in `.env`.

## Windows client profile

Use the exact reviewed Windows amd64 release asset and verify its SHA-256 before
execution. The target command shape is:

```powershell
wstunnel.exe client `
  -L 'udp://127.0.0.1:51820:127.0.0.1:51820?timeout_sec=0' `
  --tls-verify-certificate `
  --dns-resolver-prefer-ipv4 `
  wss://<EDGE_FALLBACK_DNS_NAME>:443
```

Create a **separate local WireGuard fallback profile** from the user's existing
client material. Change only the transport-facing values required for the
fallback, in particular:

```text
Endpoint = 127.0.0.1:51820
MTU = 1280   # initial recovery baseline; re-test because WSS adds overhead
```

Do not commit or paste the resulting WireGuard config/private key.

The fallback is accepted only if the same real-client contract passes:

```text
stable DNS
full HTTPS payload completes
expected public egress IP
fresh server WireGuard handshake
acceptable throughput for the selected profile
```

## Android status

Upstream wstunnel publishes an Android arm64 release asset and documents an
Android WireGuard-over-wstunnel path, but **this repository does not yet claim
Android operational acceptance**. Android fallback remains blocked until a real
device demonstrates:

```text
Wi-Fi
cellular
sleep/wake
full HTTPS payload
expected egress IP
fresh server handshake
```

No Android fallback profile is promoted merely because the binary exists.

## MTU rule for the fallback

WSS/TCP adds another encapsulation layer. Upstream explicitly warns that a
WireGuard MTU that is safe natively may still fragment when carried through
wstunnel.

Therefore:

1. start from the repository recovery baseline `1280`;
2. never raise the MTU for fallback without a full-payload A/B test;
3. if 1280 still fragments/stalls, test downward in controlled steps;
4. keep the fallback MTU decision separate from the native-profile optimum.

## Promotion / rollback

Promotion is profile-specific:

```text
native-wireguard: PASS|RETEST|FAIL
wstunnel-wss:     PASS|RETEST|FAIL
```

Enabling the fallback must not rewrite the native profile. Rollback is simply:

1. deactivate the fallback WireGuard profile;
2. stop the local wstunnel client;
3. reactivate the native WireGuard profile;
4. server-side wstunnel may be stopped independently without changing wg-easy
   persistent state.

## Explicit non-goals

This P1 design does not:

- attempt to accelerate a `REJECT_NODE` base route;
- silently fail over between transports;
- expose the wg-easy admin UI;
- install `udp2raw`, UDPspeeder, Hysteria, SOCKS, or a generic proxy;
- claim Android support before real-device evidence;
- place TLS/WireGuard secret material in the repository.

`udp2raw` and UDPspeeder remain P2 experiments gated by measured UDP-specific
impairment or packet/burst-loss evidence.
