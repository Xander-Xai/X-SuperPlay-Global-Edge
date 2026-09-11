# Resilient Global Edge — public requirements

This document states reusable requirements only. It intentionally contains no
incident samples, live topology, provider, endpoint, or production result.

## Goal

Provide an additive, evidence-gated transport design that can observe
application health, detect degradation, recommend a fallback, and recover
without silently changing credentials or runtime state.

## Requirements

- Keep the baseline WireGuard deployment independently usable and reversible.
- Treat Reality and Hysteria2 as opt-in, separately configured transports.
- Measure application success, latency, loss, throughput, and connection age
  using the same targets and bounded windows for each transport.
- Require fresh evidence for port ownership, identity, firewall state, and
  rollback before any listener or route change.
- Keep credentials, certificates, client profiles, and raw evidence outside
  Git; use placeholders in examples.
- Never equate process presence, one handshake, or one HTTP status with
  application reliability.
- Keep automatic runtime mutation out of the public reference implementation;
  operator-approved actions must be explicit and auditable.

## Acceptance boundary

Local and CI checks may use synthetic fixtures and ephemeral containers. A
production-ready claim requires independently collected, time-based evidence
and a reviewed rollback package; this repository does not contain that
evidence.
