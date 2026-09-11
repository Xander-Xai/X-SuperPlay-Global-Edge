# Local Development

## Purpose

P2 validates the runtime definition before server procurement. Local development proves configuration correctness and reproducibility; it does **not** prove overseas routing quality.

## Supported development workflow

The deployment target is a Linux host. A Windows/macOS development machine may still render and validate the Compose model, but a full WireGuard container runtime depends on Linux kernel/network capabilities and should not be treated as equivalent to the future VPS.

Start from the tracked template:

```bash
cp .env.example .env
```

Keep `.env` local and untracked.

Validate the configuration:

```bash
bash scripts/validate.sh .env
```

Run the repository self-test (script syntax, negative/failure-path validation,
secret scan, documentation link check, and — when Docker is available — a
Compose render):

```bash
bash scripts/self-test.sh
```

Run the host preflight to verify OS/Docker/kernel/ports/disk readiness:

```bash
bash scripts/preflight.sh .env
```

On a compatible Linux host, start the stack through the operator script
(validate + up + wait-for-healthy + healthcheck):

```bash
bash scripts/deploy.sh .env
```

Inspect state:

```bash
bash scripts/status.sh .env
bash scripts/healthcheck.sh .env        # L1 control plane
bash scripts/wireguard-check.sh .env    # L2 data plane (pre-onboarding: NOT_CONFIGURED is fine)
```

Stop without deleting persistent WireGuard state:

```bash
bash scripts/destroy.sh --yes .env
```

Do not use `down -v` / `destroy.sh --yes --volumes` unless the persistent
state is intentionally being destroyed (take a backup first).

## Web administration access

The baseline publishes the wg-easy Web UI only on:

```text
127.0.0.1:${WG_ADMIN_PORT}
```

Default:

```text
http://127.0.0.1:51821
```

`INSECURE=true` is intentionally scoped to this loopback-only HTTP path. It must not be combined with a public `WG_ADMIN_BIND=0.0.0.0` baseline. On a future VPS, use an SSH tunnel or a separately reviewed private/TLS access design.

## First wg-easy setup

wg-easy v15 stores normal setup state — including the endpoint Host/Port,
admin identity, and clients — in its persistent `/etc/wireguard` volume.
P2 does not place admin credentials or `INIT_PASSWORD` in Git.

During interactive first setup, keep the endpoint aligned with the
repository metadata:

- Host MUST equal `EDGE_PUBLIC_HOST`;
- Port MUST equal `EDGE_WIREGUARD_PORT` (default `51820`).

After onboarding, `scripts/wireguard-check.sh` treats a real listen port
that differs from `EDGE_WIREGUARD_PORT` as `STATE=MISMATCH` (hard failure):
change the port through the admin UI, never behind the operator. Automated
secret injection is deliberately deferred to P3/P5.

## Health semantics

The Compose healthcheck (L1 control plane) probes the local wg-easy HTTP
process on container port `51821`. It deliberately does **not** require `wg
show` to report an interface, because a fresh v15 installation may not have
created the WireGuard interface until interactive setup is complete.

This healthcheck answers "is the management service alive?". Tunnel/interface
correctness, listen-port consistency, and handshake visibility are the L2
data-plane check (`scripts/wireguard-check.sh`); real client connectivity and
network acceptance are separate P8/P9 checks (`docs/acceptance.md`).

## Operator scripts (P5)

All lifecycle actions go through `scripts/`; raw `docker compose` is reserved
for debugging. The interface is:

| Action | Command |
| ------ | ------- |
| Validate env | `bash scripts/validate.sh <env>` |
| Host preflight | `bash scripts/preflight.sh <env>` |
| Deploy | `bash scripts/deploy.sh <env>` |
| Health | `bash scripts/healthcheck.sh <env>` |
| Status | `bash scripts/status.sh <env>` |
| Backup | `bash scripts/backup.sh <env> [dir]` |
| Restore | `bash scripts/restore.sh [--yes] <backup.tgz> <env>` |
| Destroy | `bash scripts/destroy.sh [--yes] [--volumes] <env>` |

Scripts resolve the env file in this order: explicit argument →
`EDGE_ENV_FILE` → `${EDGE_ROOT}/.env`. Rendering/execution always targets the
repo's `deploy/docker-compose.yml`. See `scripts/README.md`.

## P3–P6 governance

- Secrets & rotation: `docs/secret-rotation.md`, `docs/security.md`.
- Client naming: `docs/client-naming.md`.
- Upgrades & rollback: `docs/upgrade-rollback.md`.
- CI runs ShellCheck, YAML parse, secret scan, repository self-test, Compose
  render, and a real stack lifecycle (deploy → health → backup → destroy →
  restore → health → cleanup) on every push/PR.

## Current version contract

The reviewed release is exactly:

```text
ghcr.io/wg-easy/wg-easy:15.4.0
```

`WGEASY_IMAGE` must remain that exact value in the P2 baseline. `latest`, `edge`, `development`, mutable major/minor tags, and prereleases are not accepted as substitutes. Version upgrades require an explicit repository change, upstream review, and validation run.

## Local limitations

Local development cannot establish evidence for:

- overseas public IPv4 behavior;
- cloud firewall/security-group behavior;
- China-to-overseas route quality;
- evening packet loss and jitter;
- provider/region stability;
- final tunnel egress quality.

These remain P8/P9 concerns.

## Completion criteria

P2 is complete only when:

1. the reviewed image release is exact-version pinned;
2. Compose has persistent state, explicit networking, restart, healthcheck, and bounded logging;
3. admin exposure is loopback-only by default;
4. `.env.example` contains no real credential;
5. `scripts/validate.sh` rejects image drift and unsafe baseline configuration;
6. CI successfully renders the Compose model without production secrets.
