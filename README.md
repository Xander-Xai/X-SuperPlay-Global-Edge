# X-SuperPlay Global Edge

An evidence-gated, self-hostable edge networking reference stack. It combines
Docker Compose, WireGuard, optional Xray Reality/Hysteria2 transports, and a
read-only health API with a small desktop observer.

This repository documents reusable product mechanisms. Real endpoints,
credentials, host topology, runtime evidence, and operator records belong in
an external private store.

## Components

- `deploy/` — local Compose stacks and schema-only transport examples.
- `client/` — Mihomo and WireGuard example profiles using placeholders.
- `services/edge-health-api/` — bounded read-only health API.
- `tools/edge-health-agent/` — local probe, evidence, and alert primitives.
- `apps/edge-desktop/` — Tauri/React observation client.
- `scripts/` — validation, health, regression, and recovery helpers.
- `docs/` — architecture, security, acceptance, and recovery contracts.

## Safety boundary

All examples are local, synthetic, or placeholder-only. Do not commit a
production `.env`, client configuration, private key, token, provider account
identifier, real endpoint, or raw production evidence. CI must run against
ephemeral state and a runner isolated from production infrastructure.

## Local checks

```bash
bash scripts/validate.sh .env.example
bash scripts/secret-scan.sh
bash scripts/open-source-readiness.sh
bash scripts/self-test.sh
```

Docker-dependent checks are optional locally and run in CI when a daemon is
available. No command in this repository authorizes SSH, firewall, DNS, or
production service changes.

Public pull requests and pushes are validated on disposable GitHub-hosted
`ubuntu-latest` and `windows-latest` runners. Optional self-hosted runners are
not required for public CI and may only be used for separately reviewed,
specialized private experiments.

## License and provenance

The project is MIT-licensed. See `LICENSE` and
`docs/client/reference/provenance.md` for third-party clean-room provenance.
