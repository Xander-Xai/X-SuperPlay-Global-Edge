# Project roadmap

This roadmap tracks public engineering capabilities only. Private rollout,
procurement, revenue, host, and incident records are intentionally excluded.

## Foundations

- [x] MIT license and repository security baseline.
- [x] Environment template with external-secret boundary.
- [x] Docker Compose configuration and deterministic validation.
- [x] Shell, Python, TypeScript, and Rust test surfaces.

## Reliability

- [x] Read-only health API and evidence schema.
- [x] WireGuard state and freshness checks.
- [x] Additive transport examples for Reality and Hysteria2.
- [x] Evidence-gated recovery policy with manual mutation boundary.
- [ ] Complete a reproducible synthetic protocol comparison.
- [ ] Complete time-based soak tests in an isolated environment.

## Client

- [x] React/Tauri observer with stale and unavailable-state handling.
- [x] Explicit server identity and credential separation contracts.
- [ ] Expand local fixture coverage for transport failure modes.

## Release gates

Every public change must pass the secret scanner, open-source privacy scanner,
static checks, relevant tests, documentation-link checks, and license/provenance
review. Production deployment and external credential handling remain outside
this public repository.
