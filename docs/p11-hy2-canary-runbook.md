# P11 Hysteria2 Additive Canary Runbook

Status: `PREPARATION_ONLY`

This runbook defines a future Founder-authorized canary. It does not deploy
Hysteria2, access the production VPS, switch client routes, or change any
runtime acceptance gate.

## Reuse and disposition

| ASSET | DECISION | REASON |
| --- | --- | --- |
| `deploy/g1-v2/docker-compose.yml` | `REUSE_AS_IS` | Canonical additive Compose project; Reality and WireGuard remain separate services. |
| `deploy/g1-v2/hysteria/config.yaml.example` | `REUSE_AS_IS` | Conservative schema-only template with external TLS/password paths. |
| `scripts/g1-v2-deploy.sh` | `EXTEND_EXISTING` | Adds `--check-hy2`, `--up-hy2`, and `--down-hy2` service-scoped lifecycle operations. |
| `scripts/g1-v2-protocol-abc.ps1` | `REUSE_AS_IS` | Existing application-level measurement schema for WIREGUARD/HY2/REALITY. |
| `scripts/g1-v2-validate.sh` | `REUSE_AS_IS` | Existing static contract validator; not a runtime functional test. |
| `docs/g1-v2-port-ownership-adr.md` | `REUSE_AS_IS` | Generic ownership gate remains authoritative before any listener activation. |
| `docs/g1-v2-resilient-global-edge-prd.md` | `REUSE_AS_IS` | Public requirements and claim boundaries remain unchanged. |
| `client/mihomo/config.yaml.example` | `EXTEND_EXISTING` | Existing Mihomo-compatible isolated canary nodes are documented; normal node set is not overwritten. |

`NEW_PARALLEL_HY2_STACK=FORBIDDEN`.

## Upstream identity

The official Hysteria upstream release is `app/v2.12.2` (tag `v2.12.2`). The
existing image pin is retained without change:

```text
HYSTERIA_UPSTREAM_VERSION=app/v2.12.2
HYSTERIA_IMAGE=tobyxdd/hysteria:v2.12.2
HYSTERIA_IMAGE_DIGEST=sha256:9725222899831fd80ca802c4f6984b5f6ad96672248a25dd7d8f781f5029f87c
HYSTERIA_IMAGE_CHANGE_REQUIRED=NO
```

The server template uses documented `listen`, `tls`, password `auth`, and
proxy masquerade fields. Bandwidth, Brutal tuning, custom QUIC windows, port
hopping, obfuscation, and kernel tuning remain unset/default for attribution.
Mihomo's existing `hysteria2` proxy type is the client compatibility target.

## Service-scoped lifecycle

The wrapper pins every G1-v2 Compose invocation with the explicit additive
project name `x-superplay-global-edge-g1-v2` (overridable only through the
reviewed `G1_V2_COMPOSE_PROJECT_NAME` variable). The HY2 modes fail closed if
that name is changed to the existing WireGuard namespace
`x-superplay-global-edge`; a surrounding `COMPOSE_PROJECT_NAME` cannot capture
the HY2 lifecycle because the wrapper passes Compose `-p` explicitly.

`--check-hy2` validates the image returned by `docker compose config --images`,
not merely the shell's `HYSTERIA_IMAGE` expansion. It requires the exact
reviewed tag and digest and prints only the resolved image identity. The
bounded local regression procedure is:

```bash
bash scripts/g1-v2-hy2-safety-regression.sh
```

It exercises a Compose-supported unreviewed-image environment file, a root
`COMPOSE_PROJECT_NAME` collision, and the reviewed pin. A temporary Docker
command shim passes through only read-only Compose `config` operations and
blocks/logs every mutating command, so no mutation can reach the real Docker
daemon even if a guard under test regresses.

All commands below are future operator actions. This preparation task does not
run `--up-hy2` or `--down-hy2`.

```bash
# Non-mutating check; no service is started.
G1_V2_RUNTIME_DIR=/absolute/external/runtime/g1-v2 \
  bash scripts/g1-v2-deploy.sh --check-hy2

# Future implementation path; requires a fresh port gate and external files.
G1_V2_PORT_OWNERSHIP=PASS \
G1_V2_RUNTIME_DIR=/absolute/external/runtime/g1-v2 \
  bash scripts/g1-v2-deploy.sh --up-hy2

# Future rollback; stops/removes only hysteria2.
bash scripts/g1-v2-deploy.sh --down-hy2
```

`--up-hy2` runs only `docker compose ... up -d --no-deps hysteria2`. It must
not recreate Reality. `--down-hy2` uses service-scoped stop/removal and must
not run whole-project `docker compose down`.

## Runtime readiness and secret boundary

The canonical external files are:

```text
runtime/g1-v2/hysteria/config.yaml
runtime/g1-v2/hysteria/server.crt
runtime/g1-v2/hysteria/server.key
```

They are outside Git. The tracked example remains schema-only. Readiness is
operator input, not an automatic acquisition step:

```text
HY2_AUTH_MATERIAL_READY=YES/NO
HY2_TLS_CERT_READY=YES/NO
HY2_TLS_KEY_READY=YES/NO
HY2_CLIENT_SNI_READY=YES/NO
HY2_TLS_MATERIAL=BLOCKED_PENDING_OPERATOR_INPUT
```

Never commit passwords, private keys, populated client URIs/configs, production
hostnames/IPs, or credentials. Do not add ACME behavior in this canary prep;
certificate acquisition and TCP/80 or TCP/443 ownership require a separate
review.

## Isolated client canary

Use a copied, separate Mihomo canary profile/provider. Do not replace the
user's normal Clash Verge/Mihomo configuration and do not enable TUN capture
for this preparation. The two nodes are placeholders only:

```yaml
HY2_CANARY_NODE:
  type: hysteria2
  server: <EDGE_HOST>
  port: 443
  password: <HY2_PASSWORD_EXTERNAL>
  sni: <HY2_SNI>
  skip-cert-verify: false
  bandwidth: unset

REALITY_CANARY_NODE:
  type: vless
  server: <EDGE_HOST>
  port: 443
  uuid: <REALITY_UUID_EXTERNAL>
  servername: <REALITY_SNI>
```

Neither node is active merely because it appears in a template. Functional
evidence requires a real application request through the selected transport.

## Future same-VPS A/B/C contract

Reuse `scripts/g1-v2-protocol-abc.ps1` on the same Windows host, physical
underlay, VPS, public targets, sample count, timeout, and adjacent windows:

```text
A = WIREGUARD UDP/51820
B = HY2 UDP/443
C = VLESS REALITY TCP/443
TARGETS = GitHub, gstatic HTTP-204, Cloudflare
```

Each window retains success rate, consecutive failures, DNS/connect/TLS/TTFB/
total latency, payload completion, measurable throughput, and connection age.
Do not compare WireGuard ICMP with HY2 HTTPS and call it A/B/C. Include the
same bounded download target for each transport where available.

The future runner must join each protocol window with server-side
before/during/after samples for NIC errors/drops, UDP buffer errors, UDP input
errors, IP discards, TCP retransmits, conntrack count/max, softnet drops, and
CPU/RAM where available. The open `ACTIVE_WG_CORRELATED_RECHECK` should close
opportunistically during window A; this preparation performs no such samples.

## Live precheck and rollback

Immediately before a separately authorized implementation window, freshly
verify:

```text
TCP/443   = Reality
UDP/443   = NONE
UDP/51820 = WireGuard
TCP/51821 = loopback WG admin
```

Capture `docker ps`, Compose project/service state, Reality and WireGuard
container identities, SSH reachability, firewall state when readable, and the
current port-ownership record. If UDP/443 is not free:

```text
PORT_UDP_443_PRECHECK=FAIL
STOP
```

Never evict or move an existing listener automatically.

The backup/rollback manifest must cover Compose identity, Reality and
WireGuard identities/state, any external HY2 files being added, readable
firewall state, port ownership, and SSH control path. Rollback is service-scoped
HY2 removal, with the target state:

```text
HY2 absent
UDP/443 returned to prior owner/free state
Reality unchanged
WireGuard unchanged
SSH intact
```

Triggers include Reality/WireGuard/SSH regression, unexpected port ownership,
HY2 startup loops, failed application path, or any unplanned firewall/runtime
change.

## Evidence vocabulary and interpretation

Keep these facts separate:

```text
HY2_PROCESS_PRESENT
HY2_UDP443_LISTEN
HY2_CLIENT_HANDSHAKE
HY2_APPLICATION_PATH_FUNCTIONAL
REALITY_PRESENT
REALITY_FUNCTIONAL
```

Container `Up` is not `HYSTERIA2_FUNCTIONAL=TRUE`; Reality presence is not a
functional handshake. Interpret the eventual matrix conservatively:

```text
WG degraded + HY2 degraded + Reality stable -> UDP path/treatment suspicious
WG degraded + HY2 stable + Reality stable -> WireGuard-specific path/state suspicious
all three degraded -> shared client/underlay/VPS/route layer suspicious
all three stable -> intermittent/time-dependent degradation remains possible
HY2 stable briefly -> canary success only, never production readiness
```

## Preparation gate boundary

```text
SEGMENTED_BASELINE_COMPLETE=TRUE
MTU_PMTU_VERIFIED=FALSE
NAT_KEEPALIVE_EVALUATED=FALSE
SAME_VPS_PROTOCOL_ABC_COMPLETE=FALSE
DIAGNOSTIC_COMPLETE=FALSE
IMPLEMENTATION_COMPLETE=FALSE
READY_FOR_SOAK=FALSE
PRODUCTION_READY=FALSE
HY2_DEPLOYED=NO
HYSTERIA2_FUNCTIONAL=FALSE
REALITY_FUNCTIONAL=UNKNOWN
```

`PREPARATION_ONLY=TRUE`; no runtime gate is advanced by this document.

## Verification sources

- [Official Hysteria release `app/v2.12.2`](https://github.com/apernet/hysteria/releases/tag/app/v2.12.2)
- [Official Hysteria full server configuration](https://v2.hysteria.network/docs/advanced/Full-Server-Config/)
- [Mihomo Hysteria2 proxy configuration](https://wiki.metacubex.one/en/config/proxies/hysteria2/)
