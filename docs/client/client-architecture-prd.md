# P13-001 X-SuperPlay Edge Client Architecture PRD

**Status:** Design only; no client implementation is included.

**Repository:** X-SuperPlay-Global-Edge

**Phase:** P13-001

## 1. Product positioning

The X-SuperPlay Edge Client is a read-only observation client for an approved
edge service. It presents node identity, health,
runtime-state, evidence, alerts, and exported metrics through the existing
Read-Only State / Reliability API. It is not the packet path and it is not a VPN core
replacement.

The client must never become a second implementation of WireGuard, Xray
Reality, Hysteria2, routing, encryption, or tunnelling. Those functions remain
owned by the Edge Runtime. A client action, if a later phase is authorized to
add one, is a request to a separately governed control API; it is not a direct
mutation of runtime files or a substitute for the runtime's protocol logic.

```text
                       control plane (future client)
  Desktop Client / Web Dashboard / Mobile Client
                         |
                         | HTTPS or explicitly approved local transport
                         v
             Read-Only State / Reliability API
       health | node state | identity | events | metrics
                         |
                         v
                    Edge Runtime
       Health Agent -> Evidence Store -> Alert Rules
       WireGuard / Xray Reality / Hysteria2 data plane
```

The current P13 design uses read-only calls. This preserves a clear boundary:
the client can explain what the edge observed, while the runtime remains the
only authority for traffic processing and service state.

## 2. Goals

1. Define one API-first data contract that can serve desktop, Android, and web
   consumers.
2. Make current state, historical health, alert state, and metrics visibly
   traceable to the P12 evidence pipeline.
3. Degrade explicitly when evidence or a service state is unavailable; do not
   turn an unknown observation into a healthy or failed assertion.
4. Keep credentials, local permissions, and future write capabilities isolated
   from the read-only observation path.
5. Make client polling, caching, and schema-version handling predictable.

## 3. Non-goals and hard boundary

This phase does not:

- replace or reimplement a VPN core, WireGuard, Xray Reality, Hysteria2, or
  any other protocol;
- rewrite a client profile or change protocol, endpoint, routing, or cipher
  configuration;
- create a production desktop, Android, web, or UI application;
- modify Edge Runtime files, Docker, VPS state, WireGuard, Xray, or server
  configuration;
- add authentication, notifications, node orchestration, automatic recovery,
  traffic switching, or privileged write endpoints;
- deploy the API, Prometheus, Grafana, or any client service.

The deliverables are contracts and architecture documents only.

## 4. Actors and trust boundaries

| Actor | Responsibility | Trust boundary |
|---|---|---|
| Client shell | Render API responses, cache bounded read-only state, show evidence links | Untrusted UI process; no runtime secrets |
| API adapter | Validate and expose stable versioned responses | Narrow read-only interface; no data-plane writes |
| Edge Runtime | Run probes and protocols; own observed state | Privileged data-plane boundary |
| Operator | Interpret evidence and approve future changes | Human approval boundary |

The client must treat API data, error strings, labels, and evidence text as
untrusted display data. A malformed response is a visible unavailable/unknown
state, not a reason to infer a replacement value.

## 5. Logical client architecture

### 5.1 Client shell

The shell owns lifecycle, windowing/navigation, platform integration, and
permission prompts. It does not own health calculations or protocol state.
The shell should expose a minimal bridge to the UI layer and reject methods
outside the approved read-only command set.

### 5.2 API client and contract adapter

The API client is the only component that communicates with the Read-Only
State / Reliability API. It supplies a base URL, request timeout, schema/API version, and bounded
retry policy for idempotent GET requests. A response is accepted only after
status, content type, and required fields are checked.

The adapter normalizes the six client-facing resource families:

- node status, identity, and service declarations;
- current health and historical health;
- alert events and resolved state;
- Prometheus text metrics for diagnostics and future integrations.

It must not calculate a new health score, reinterpret a TCP result as a
Reality result, or merge latency phases. Existing API values remain the source
of truth.

### 5.3 State store and presentation model

The state store keeps the latest accepted snapshot in memory and may cache a
bounded, explicitly marked copy for display continuity. Every displayed
snapshot carries its source timestamp and freshness state (`fresh`, `stale`,
or `unavailable`). Cached data must never be used to authorize a runtime
change.

### 5.4 Evidence and alert views

Evidence is displayed by reference and bounded metadata. Raw secrets, private
keys, reusable client profiles, and unrestricted payloads are never copied
into client logs or local storage. Alert views preserve level, reason, metric,
threshold, timestamp, and source evidence; they do not send notifications or
close/resolve an alert locally.

## 6. Read-only data flow

```text
client start
  -> load non-secret endpoint settings
  -> GET identity and capabilities
  -> GET node status and current health
  -> GET events and metrics on a bounded cadence
  -> validate and timestamp each response
  -> render fresh/stale/unavailable state
  -> retain only bounded, redacted diagnostic context
```

The API currently supports polling. A future push channel may be considered
only as a separately versioned contract; it must not bypass the same evidence
and authorization boundaries.

## 7. State and failure semantics

- `healthy`, `degraded`, and `unknown` are distinct node states.
- An unavailable WireGuard, Xray Reality, or Hysteria2 service state remains
  `unavailable`; a successful TCP probe does not prove a tunnel or Reality
  handshake.
- Empty evidence produces unknown current state and unavailable metrics where
  no sample exists.
- HTTP/API errors are transport errors for the client and must not be
  presented as a runtime failure without an evidence response.
- Stale cached state is labelled with age and source timestamp.

## 8. Security architecture

### Credential handling

P13 read-only operation should use no long-lived credential in the UI layer.
If a later deployment requires authentication, short-lived scoped tokens must
be acquired by a platform-protected broker and passed only to the API client.
Tokens must not appear in URLs, analytics, crash reports, screenshots, or
general application logs.

### Local permissions

The client requests only the permissions needed for its platform shell,
network access, and protected credential storage. It does not request raw
socket, packet-capture, administrator, service-manager, or filesystem access
to runtime configuration for observation.

### Secret isolation

The UI, API response models, evidence renderer, and metrics parser must have
no path to private keys, UUIDs, full client profiles, or reusable tunnel
secrets. Redaction happens before data enters logs or support bundles. A
future privileged operation, if approved, must use a separate process and
contract from this read-only client.

## 9. Compatibility and lifecycle

The API base path is versioned (`/api/v1`). Clients must ignore additive
fields, fail closed on missing required fields, and show an explicit
unsupported-version state when a major contract is not understood. The
Prometheus endpoint is text and is parsed independently from JSON resources.

Client releases should record API version, client version, source timestamp,
and schema validation outcome in local diagnostics without recording secrets.

## 10. Future extensions (not implemented)

The contract leaves room for multiple nodes by retaining `node_id`, region,
provider, endpoint identity, source timestamps, and per-node evidence. A
future client could compare nodes or request an operator-approved action, but
node selection, failover, write authorization, and recovery remain separate
designs. No multi-node deployment or automatic recovery is part of P13-001.

## 11. Acceptance boundary

P13-001 is complete when the three documents in `docs/client/` define a
consistent control-plane model, API contract, technology trade-off, and
security boundary, with no source-code, runtime, server, WireGuard, or Xray
changes.
