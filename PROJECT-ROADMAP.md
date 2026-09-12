# Project roadmap

This roadmap tracks public engineering capabilities only. Private rollout,
procurement, revenue, host, and incident records are intentionally excluded.

The next client milestone is intentionally modeled at the architecture-pattern
level after mature Tauri proxy clients such as Clash Verge Rev: the desktop UI
is a control surface, a local controller owns runtime lifecycle, a dedicated
network core owns the data plane, and privileged system integration is isolated
behind a narrow boundary. No upstream GPL implementation code, assets, or
branding may be copied into this MIT repository.

## Current baseline

- [x] MIT license and repository security baseline.
- [x] Environment template with external-secret boundary.
- [x] Docker Compose configuration and deterministic validation.
- [x] Shell, Python, TypeScript, and Rust test surfaces.
- [x] Read-only health API and evidence schema.
- [x] WireGuard state and freshness checks.
- [x] Additive Reality and Hysteria2 transport examples.
- [x] Evidence-gated recovery policy with manual mutation boundary.
- [x] React/Tauri desktop observer with stale and unavailable-state handling.
- [x] Explicit server identity and credential separation contracts.

## Milestone 0.2 — connection-capable desktop client

The release client must evolve from an observer into the normal entry point for
establishing and supervising connectivity. Users should not need to launch a
separate WireGuard application for the primary daily-use path.

### P0 — runtime and control-plane architecture

- [ ] Write an ADR for the local runtime architecture: `Desktop UI -> local
  controller -> managed network core -> system network`.
- [ ] Evaluate the network-core strategy with a reproducible spike. Compare a
  managed multi-protocol core candidate with directly supervising Xray,
  Hysteria2, and WireGuard components. Record protocol coverage, TUN/system
  proxy support, Windows behavior, upgrade model, binary size, and license
  implications before selecting a default.
- [ ] Define a stable local controller API for connect, disconnect, status,
  active transport, runtime version, and bounded diagnostics.
- [ ] Add a runtime supervisor with start/stop/restart, readiness checks, crash
  detection, bounded restart policy, and clean shutdown.
- [ ] Add runtime binary provenance and integrity verification before execution.
- [ ] Compile local profile state into generated runtime configuration without
  committing endpoints, credentials, private keys, or tokens.
- [ ] Preserve the current observer API as telemetry input; do not couple UI
  components directly to child-process internals.

### P0 — Windows traffic takeover

- [ ] Implement a system-proxy mode owned by the desktop client.
- [ ] Implement a TUN-mode prototype with explicit privilege requirements and a
  reversible install/start/stop path.
- [ ] Add a narrow privileged helper/service boundary for operations that cannot
  safely run in the normal desktop process.
- [ ] Restore proxy, route, DNS, and TUN state after normal disconnect, core
  crash, desktop crash, failed upgrade, or interrupted startup.
- [ ] Add a startup reconciliation pass so stale state from a previous session
  cannot silently leave the machine half-connected.

### P0 — transport policy

- [ ] Make VLESS + Reality the first primary-path candidate for normal client
  traffic where the selected core supports it.
- [ ] Keep Hysteria2 as an optional high-performance/alternate path.
- [ ] Keep WireGuard supported during migration as an administration, recovery,
  or fallback path instead of requiring the standalone WireGuard GUI.
- [ ] Represent transport state explicitly: `disabled`, `starting`, `ready`,
  `degraded`, `failed`, `cooldown`, and `stopped`.
- [ ] Do not enable unattended transport mutation until failover behavior has
  passed synthetic and soak acceptance gates.

### P0 — desktop product flow

- [ ] Add first-class Connect / Disconnect actions to the Tauri desktop client.
- [ ] Show connection mode, active transport, endpoint alias, session age,
  latency, loss, last application-level probe, and failure reason.
- [ ] Distinguish `core not running`, `transport not ready`, `system proxy/TUN
  not applied`, and `Internet acceptance failed` instead of exposing one generic
  offline state.
- [ ] Add tray controls for connect/disconnect and current connection state.
- [ ] Ensure the UI remains usable when the managed core or privileged service
  is unavailable.

## Milestone 0.3 — profiles, routing, and resilient failover

### P1 — profile management

- [ ] Add local profile create/edit/delete/select flows with schema validation.
- [ ] Separate profile metadata from secret material and runtime-generated
  files.
- [ ] Add sanitized import/export fixtures that cannot leak real infrastructure.
- [ ] Add configuration validation before any runtime restart or system-network
  mutation.
- [ ] Keep the configuration model provider-neutral; protocol-specific fields
  belong behind transport adapters or the selected core schema.

### P1 — routing modes

- [ ] Support at least `direct`, `global proxy`, and `rule-based` operating
  modes where the selected core permits them.
- [ ] Add DNS behavior and leak-prevention acceptance tests for proxy and TUN
  modes.
- [ ] Add bypass rules for loopback, local subnets, and operator-defined private
  destinations.

### P1 — evidence-gated failover

- [ ] Expand probes from process/TCP presence to application-level acceptance,
  latency, loss, throughput, and connection age.
- [ ] Add hysteresis, cooldown, minimum healthy duration, and circuit-breaker
  semantics to avoid transport flapping.
- [ ] Implement manual failover first, then gated automatic failover after soak
  evidence is reproducible.
- [ ] Preserve the last known-good configuration and provide one-step rollback.
- [ ] Record bounded local transition evidence without storing secrets or raw
  production payloads.

### P1 — service and lifecycle hardening

- [ ] Define desktop/service ownership and IPC authentication boundaries.
- [ ] Verify that only approved runtime binaries/configurations can be executed
  by privileged components.
- [ ] Add boot/login startup policy and deterministic recovery after service or
  desktop upgrades.
- [ ] Add watchdog coverage for orphaned cores, duplicate runtimes, stale proxy
  settings, and stale TUN adapters.

## Milestone 0.4 — daily-driver UX and distribution

### P2 — usability

- [ ] Add a connection dashboard focused on actionable state rather than raw
  implementation details.
- [ ] Add node/transport latency testing and a compact diagnostics view.
- [ ] Add bounded logs with redaction and an explicit diagnostics export flow.
- [ ] Add local backup/restore for non-secret preferences and sanitized profile
  metadata.
- [ ] Add update channels and rollback-safe desktop/runtime upgrade handling.

### P2 — release engineering

- [ ] Produce reproducible Windows installer artifacts with checksums and
  runtime-component manifests.
- [ ] Test clean install, upgrade, downgrade/rollback, uninstall, and interrupted
  install scenarios.
- [ ] Ensure uninstall restores system proxy/TUN/network state and removes only
  resources owned by this application.

## Reliability and acceptance gates

- [ ] Complete a reproducible synthetic comparison for Reality, Hysteria2, and
  WireGuard paths.
- [ ] Complete time-based soak tests in an isolated environment.
- [ ] Demonstrate that the released desktop client can establish a working
  connection without requiring the standalone WireGuard GUI for the selected
  primary path.
- [ ] Demonstrate recovery from core crash, desktop crash, service crash,
  network change, sleep/resume, and temporary endpoint failure.
- [ ] Demonstrate that failed connection attempts do not leave persistent proxy,
  route, DNS, or TUN mutations behind.
- [ ] Keep application-level success as the acceptance signal; process presence
  or a single TCP/UDP handshake is insufficient.

## License and provenance gates

- [ ] Treat Clash Verge Rev as an architecture/reference study only. Do not copy
  GPL-3.0 source code, UI assets, text, branding, or implementation-specific
  material into this MIT repository.
- [ ] Review the license and redistribution requirements of every candidate
  bundled network core before shipping it inside a release artifact.
- [ ] Document third-party binary provenance, version, digest, source location,
  and applicable license in the release manifest.

## Release gates

Every public change must pass the secret scanner, open-source privacy scanner,
static checks, relevant tests, documentation-link checks, and license/provenance
review. Production deployment and external credential handling remain outside
this public repository.
