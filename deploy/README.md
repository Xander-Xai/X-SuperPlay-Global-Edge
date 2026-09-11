# Deployment Assets

This directory owns deployable runtime definitions.

## Current P2 baseline

`docker-compose.yml` is based on the reviewed wg-easy v15.4.0 upstream deployment model and intentionally narrows the exposure surface for this project.

Key properties:

- immutable default runtime image identity: `ghcr.io/wg-easy/wg-easy:15.4.0@sha256:0e7bc9d34e86ddcaa92bc700d4d7dc9b33291dbc07ac8d13382f7c2095f949ec`;
- named persistent volume for `/etc/wireguard`;
- WireGuard UDP port published from `EDGE_WIREGUARD_PORT` (default 51820);
- Web UI bound to host loopback only by default;
- repository metadata `EDGE_PUBLIC_HOST` documents the expected public
  endpoint. It is **not** passed to the container: wg-easy v15 keeps the
  endpoint (Host/Port) in its own persistent state, written during first
  onboarding. Onboarding Host MUST equal `EDGE_PUBLIC_HOST` and Port MUST
  equal `EDGE_WIREGUARD_PORT`. `scripts/wireguard-check.sh` fails loudly when
  the real listen port drifts from `EDGE_WIREGUARD_PORT`;
- G1 IPv4-first data plane via `DISABLE_IPV6` rendered from
  `EDGE_DISABLE_IPV6` (default true); the bridge network keeps the upstream
  IPv6 structure, but the VPN hands out IPv4 only;
- `NET_ADMIN` and `SYS_MODULE` capabilities required by the upstream model;
- required forwarding sysctls;
- explicit service healthcheck (L1: control plane alive);
- `restart: unless-stopped`;
- bounded Docker local logs;
- provider-independent configuration.

## Immutable runtime identity

The human-readable tag remains useful for review, but the digest is the actual
artifact lock. Both `.env.example` and the Compose fallback contain the same
tag+digest value. `scripts/validate.sh` and repository CI reject:

- `:latest`;
- tag-only `15.4.0`;
- a different release;
- a different digest.

If the pinned digest becomes unavailable upstream, deployment must fail closed.
Do not remove the digest as a workaround; review and pin a replacement artifact.

## Admin UI boundary

The baseline uses plain HTTP only on a loopback-bound host port:

```text
127.0.0.1:51821 -> container:51821
```

This makes local setup possible without declaring the Web UI public. A future VPS must use an SSH tunnel or another separately reviewed TLS/private-access mechanism. Do not change `WG_ADMIN_BIND` to `0.0.0.0` merely for convenience.

## Persistent state

The named volume `etc_wireguard` contains wg-easy/WireGuard state. Normal `docker compose down` keeps it. Destructive removal of the volume is a recovery/destroy operation and is not part of P2.

## Helper images

Operator scripts use `alpine:3.20` as a pinned, throwaway helper for
volume backup/restore/size operations (see `scripts/backup.sh`,
`scripts/restore.sh`, `scripts/status.sh`). It is not part of the long-running
service runtime. Future hardening may also digest-pin helper images; this does
not weaken the exact identity of the production wg-easy service image.

## Phase boundary

- P1: directory and ownership contract — DONE.
- P2: reviewed, version-pinned Docker Compose stack — DONE.
- P3/P4: secret/access policies and security baseline — DONE (see `docs/`).
- P5: deployment/recovery automation — DONE (`scripts/`). Note the
  distinction: **P5 Host Bootstrap** (OS/Docker/SSH/firewall, in
  `docs/local-development.md` + `docs/deployment.md`) is separate from the
  **application deployment** (`scripts/deploy.sh`). A VPS with the host
  bootstrapped still requires first wg-easy onboarding before clients work.
- P6: local/CI verification incl. stack-lifecycle job — DONE (`.github/`).
- P7/P8: server selection and first remote deployment use the same core
  definitions. Pre-P8 engineering readiness (config correctness,
  observability, backup/restore consistency, immutable artifact identity and
  real-client evidence tooling) is tracked under P8 acceptance; P8 itself
  stays pending until a real VPS run produces client evidence.

## Rules

1. Do not commit production secrets.
2. Do not use floating or tag-only runtime images for wg-easy.
3. Keep provider-specific values outside the core Compose definition where practical.
4. A deployment must be reproducible from Git plus external secrets.
5. Changes to runtime definitions require CI validation before merge.
