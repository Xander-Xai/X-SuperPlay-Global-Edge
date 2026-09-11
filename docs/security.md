# Security Baseline

This document is the independent, provider-agnostic security model for the
X-SuperPlay Global Edge deployment. It can be reviewed on its own; no server,
provider, or chat history is required to audit the policy.

Status: **P4 — enforced by repository gates + P8 host hardening runbook.**

---

## 1. Secret boundary (P3)

Never commit to Git, and never store on the host in plain sight without review:

- WireGuard private keys;
- client configuration files (`*.conf`);
- production `.env` files;
- administrative passwords / `INIT_PASSWORD`-style values;
- SSH private keys;
- cloud/API credentials;
- recovery codes / 2FA seeds;
- production inventories containing sensitive access details.

Enforcement in this repository:

- `.gitignore` excludes `.env`, `clients/`, `secrets/`, `runtime/`, `state/`,
  `backups/`, `*.conf`, `*.key`, `*.pem`, `*.p12`, `*.pfx`;
- CI rejects any tracked file matching those shapes;
- `scripts/secret-scan.sh` scans tracked content for credential patterns;
- `scripts/validate.sh` rejects admin passwords inside the runtime env template.

Rotation and lifecycle: see [`secret-rotation.md`](secret-rotation.md).

## 2. Administrative surface

The wg-easy Web UI **must stay loopback-only**. The baseline binds it to
`127.0.0.1:51821` (`WG_ADMIN_BIND`), and `scripts/validate.sh` hard-fails any
configuration that moves it to a non-loopback address.

Reach the admin UI on a remote host only through one reviewed private path:

1. SSH tunnel: `ssh -N -L 51821:127.0.0.1:51821 <host>` (recommended), or
2. a separately reviewed VPN/private network path with its own access control.

Exposing 51821 publicly — with or without a password — is out of scope for G1.

## 3. SSH target state (host, applied at P8)

Target host SSH policy (applies at first remote deployment, defined now):

```text
PermitRootLogin               prohibit-password
PasswordAuthentication        no
KbdInteractiveAuthentication  no
ChallengeResponseAuthentication no
PubkeyAuthentication          yes
UsePAM                        yes (without password auth)
AllowUsers                    <admin-user>          # non-root operator account
ClientAliveInterval           300
ClientAliveCountMax           2
```

Operational rules:

- Root login with password is never allowed. Root may authenticate only with a
  key, and routine work is done through a dedicated non-root sudo user.
- Password login is disabled only after the admin key is verified end-to-end
  over a working session (never disable the hatch before proving the key).
- Authorized keys for the operator account are added by the owner from a
  machine the owner controls; no third-party key material.
- `sshd_config` edits are validated with `sshd -t` before reload.

## 4. Host firewall baseline

Apply on the host with `ufw` (Ubuntu/Debian target) or the equivalent
`nftables` ruleset. The effective policy is default-deny on inbound.

Required host rules (G1 scope):

```text
allow 22/tcp    from <owner-admin-source-CIDRs>   # SSH, keep narrow
allow 51820/udp from 0.0.0.0/0                     # WireGuard data plane
deny  all in
```

Notes:

- 51821/tcp is **not** opened on the host firewall; it is loopback-only and
  reached via the SSH tunnel from rule 1.
- `51820/udp` is the only publicly reachable application port.
- ICMP (ping) may be allowed for acceptance testing; record the choice.
- IPv6: apply the same model to the host's IPv6 address if present; otherwise
  disable IPv6 on the host to avoid an unmanaged exposure surface.

## 5. Cloud firewall / security-group checklist

Provider security groups are reviewed together with the host firewall; the
host firewall is the source of truth, and the cloud layer is configured to
match (defense in depth, never as a replacement):

- [ ] No rule allows inbound on 51821/tcp or any admin port.
- [ ] 22/tcp source is restricted to owner-controlled CIDRs (no `0.0.0.0/0`).
- [ ] 51820/udp is open to the world (required for roaming clients).
- [ ] All other inbound rules are absent (default deny at cloud layer).
- [ ] Outbound rules, if the provider enforces them, permit the protocols the
      stack needs (WireGuard is inbound; container egress uses host routing).
- [ ] The group is attached to the instance and to no other instance.
- [ ] No provider-level "allow all" rule exists as a fallback.

## 6. Minimum-port principle

Public inbound surface at G1 is exactly:

| Port | Protocol | Bind | Purpose |
| ---- | -------- | ---- | ------- |
| 51820 | UDP | host | WireGuard data plane / client endpoint |
| 22 | TCP | host | SSH (source-restricted) |
| 51821 | TCP | loopback only | wg-easy admin UI via SSH tunnel |

Anything not in this table must be justified in a written change before it is
exposed. This table is re-checked at P8 and after any network change.

## 7. Container privilege review

The wg-easy container is reviewed against the immutable image identity stored
in `.env.example` (`ghcr.io/wg-easy/wg-easy:15.4.0@sha256:...`).

Granted (minimum required by the application):

- `NET_ADMIN`: creates/manages the WireGuard interface and routing/iptables
  rules inside the container network namespace.
- `SYS_MODULE`: loads the WireGuard kernel module when it is not built-in.

Not granted and not required:

- `privileged: true` — never used.
- Host network mode — never used; the container uses the bridge network
  `wg` with fixed IPv4/IPv6 addresses.
- `CAP_SYS_ADMIN`, `CAP_SYS_PTRACE`, device access beyond the pinned mounts —
  never granted.

Mounts:

- `/etc/wireguard` state lives in the named volume `etc_wireguard`
  (persistence, backup scope).
- `/lib/modules:/lib/modules:ro` — read-only host modules for WireGuard.

sysctls set (only the forwarding/accepting set WireGuard needs):

```text
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
```

The container is not launched with Docker `privileged: true`; upstream image
user/group defaults still apply inside the granted capability boundary.

## 8. Dependency and artifact pinning

The production runtime is pinned by **release tag + OCI index digest**, not by
tag alone:

```text
ghcr.io/wg-easy/wg-easy:15.4.0@sha256:0e7bc9d34e86ddcaa92bc700d4d7dc9b33291dbc07ac8d13382f7c2095f949ec
```

The reviewed OCI index contains the platform manifests recorded during the
2026-09-02 Pre-P8 review:

```text
linux/amd64 sha256:6b89677a396dc2831d3b5b74d720d6d50c38fd2cbe9071bc8419453f236a94b3
linux/arm64 sha256:1af452e2b9c0d6e3f433c7f94c11b1dc0bd0f73f5de9768e779486ef145380bb
```

Security consequences:

- an upstream re-push of the human-readable `15.4.0` tag cannot silently
  change the bytes used by this repository;
- `scripts/validate.sh` rejects tag-only, `:latest`, a different digest, or a
  different release;
- repository CI independently requires tag+sha256 shape in both `.env.example`
  and the Compose default;
- the exact runtime image string is recorded with each real deployed asset;
- an image upgrade/digest change is a reviewed repository change followed by
  green CI, never an ad-hoc edit on the server.

If the pinned digest is deleted/unavailable upstream, deployment must fail
closed. Do **not** fall back to the mutable tag to make deployment succeed;
review and pin a new artifact deliberately.

GitHub Actions are pinned by commit SHA with a comment carrying the tag. CI
helper images are separately documented in [`deploy/README.md`](../deploy/README.md).
See [`upgrade-rollback.md`](upgrade-rollback.md) for the change process.

## 9. Credentials and admin auth

- wg-easy v15 setup stores its state in the persistent volume. The admin
  password is created during first interactive setup through the loopback UI
  or via the untracked secret-injection path defined at P5/P8 — never through
  a committed env file.
- `scripts/validate.sh` refuses tracked env templates that contain
  `INIT_PASSWORD`/`WG_ADMIN_PASSWORD`.
- Browser session and UI credentials are treated as secrets for rotation
  purposes (see [`secret-rotation.md`](secret-rotation.md)).

## 10. Monitoring and evidence

- Health is split so one layer cannot mask another:
  - **L1 control plane** — container-level healthcheck + host-level
    `scripts/healthcheck.sh` (container running/healthy, admin UI over
    loopback). Valid before onboarding.
  - **L2 WireGuard data plane** — `scripts/wireguard-check.sh`: interface
    exists, listens on `EDGE_WIREGUARD_PORT`, peers, handshake. State machine:
    `NOT_CONFIGURED` / `READY_NO_HANDSHAKE` / `HANDSHAKE_OK` / `MISMATCH` /
    `ERROR`. Its public machine contract emits `STATE=...` as the first stdout
    line and is regression-tested by `scripts/machine-contract-test.sh`.
  - `scripts/p8-check.sh` aggregates L1+L2 + volume + restart evidence for the
    host-side P8 gate.
  - **L3 real client** — `scripts/client-e2e.ps1` runs on the actual Windows
    client and proves DNS/HTTPS/egress through the connected tunnel. Hosted CI
    is explicitly not accepted as a substitute for the user's network path.
  - `scripts/status.sh` reports container state, health, WireGuard interface
    state (when configured), and volume usage.
- Security-relevant evidence (deployments, upgrades, revocations, restores)
  is recorded in the local untracked asset/ops log with exact repository SHA,
  successful CI run id, runtime image digest and timestamps; no secrets in
  evidence.

## 11. Scope and non-goals

- G1 does not add WAF, IDS/IPS, log shipping, or secrets vaulting. If a later
  phase introduces a real workload, each addition follows the same
  review-and-gate process and gets its own security section.
- This model is provider-agnostic: no rule above references a specific cloud
  provider. Provider-specific application happens only at P7/P8 asset records.
