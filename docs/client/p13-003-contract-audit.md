# P13-003 Contract Audit and Read-Only Resilience Policy

**Base:** `9ae274e6463170e41b3b318b62f2bdd9a0485165`

**Scope:** observation-only desktop client hardening. The backend, evidence
store, protocol runtime, and deployment plane are unchanged.

## Authoritative contract sets

The backend implementation is authoritative. The audit was performed against
the route table in `services/edge-health-api/app.py`, the route builders and
models under `services/edge-health-api/`, and the validators in the desktop
API adapter.

### A. Backend actual contract

The backend exposes these ten GET resources:

`/api/v1/node/status`, `/api/v1/node/identity`,
`/api/v1/node/capabilities`, `/api/v1/node/services`,
`/api/v1/node/connection`, `/api/v1/node/metadata`,
`/api/v1/health/current`, `/api/v1/health/history`, `/api/v1/events`, and
`/metrics`.

All JSON routes return an object with additive fields allowed. `/metrics`
returns deterministic Prometheus text with `text/plain; version=0.0.4`.
The API has no write route; POST is explicitly rejected as `read_only`.

### B. Documented client contract

The client contract documents the same ten GET resources. The P13-003 repair
adds the previously omitted `/api/v1/node/connection` response and clarifies
that identity, capabilities, metadata, and service state are descriptive
observations, not control permissions or liveness proof.

### C. Desktop-consumed contract

The desktop adapter consumes all ten resources. Dashboard required resources
are status, identity, current health, and metadata. Services, connection,
history, events, and metrics are optional diagnostics with bounded fallbacks so
one unavailable diagnostic resource does not erase a useful required snapshot.
The Node view requires status, identity, and metadata; capabilities, services,
and connection remain optional.

## Consistency matrix

| RESOURCE | BACKEND_ROUTE | BACKEND_MODEL | DOCUMENTED | CLIENT_CONSUMED | CLIENT_VALIDATED | STATUS | ACTION |
|---|---|---|---:|---:|---:|---|---|
| Node status | `GET /api/v1/node/status` | `NodeStatusResponse` / runtime status payload | Yes | Yes | Yes | ALIGNED | None |
| Node identity | `GET /api/v1/node/identity` | `NodeIdentityResponse` | Yes | Yes | Yes | ALIGNED | None |
| Node capabilities | `GET /api/v1/node/capabilities` | `NodeCapabilitiesResponse` | Yes | Yes | Yes | ALIGNED | None |
| Node services | `GET /api/v1/node/services` | `NodeServicesResponse` | Yes | Yes | Yes | ALIGNED | None |
| Node connection | `GET /api/v1/node/connection` | `NodeConnectionResponse` / connection payload | No before P13-003 | Yes | Yes | DOC_MISSING | Document exact read-only response; no backend change |
| Node metadata | `GET /api/v1/node/metadata` | `NodeMetadataResponse` | Yes | Yes | Yes | ALIGNED | Enforce supported major `v1` |
| Current health | `GET /api/v1/health/current` | `HealthCurrentResponse` | Yes | Yes | Yes | ALIGNED | None |
| Health history | `GET /api/v1/health/history` | `HealthHistoryResponse` / existing summary | Yes | Yes | Yes | ALIGNED | Validate rates and non-negative latency |
| Alert events | `GET /api/v1/events` | `EventsResponse` / alert snapshot | Yes | Yes | Yes | ALIGNED | None |
| Metrics | `GET /metrics` | Prometheus text exposition | Yes | Yes | Yes | ALIGNED | Validate `text/plain` before parsing |

No `CLIENT_EXTRA`, `CLIENT_MISSING`, or `SCHEMA_MISMATCH` was found after the
documentation repair. No backend schema or implementation was changed.

## Read-only request policy

- `GET_ONLY=TRUE`.
- `DEFAULT_TIMEOUT_MS=5000`.
- `DEFAULT_MAX_ATTEMPTS=2` total attempts.
- Retry only transport failures and HTTP `502`, `503`, or `504`.
- Do not retry `400`, `401`, `403`, `404`, `405`, schema failures, malformed
  payloads, content-type mismatches, or unsupported API versions.
- Each attempt owns an `AbortController`; timeout aborts the attempt and an
  abandoned view aborts its current request. A newer refresh owns a newer
  cancellation scope, so an older result cannot overwrite it.

## Content type and schema rules

JSON resources require `application/json` or another `+json` media type.
`/metrics` requires `text/plain` (including the Prometheus version parameter).
Wrong or missing content type is `MALFORMED_RESPONSE`, even for HTTP 200.

Required fields must have the backend-declared primitive type. Additive
unknown fields are accepted. Evidence counts are non-negative integers;
health scores and rates are bounded to `[0,100]`; nullable values remain
nullable only where the backend response permits them.

## Version compatibility

The existing `/api/v1/node/metadata` response is the version source. The
desktop supports API major `v1`. A reported incompatible major produces
`UNSUPPORTED_API_VERSION`; it is never inferred from an unrelated request
failure and never silently treated as a fresh observation.

## Freshness and last-known-good policy

Freshness is independent from runtime health:

`runtime_health=HEALTHY` and `observation_freshness=STALE` is valid and must
render as last-known healthy state, clearly marked stale—not current healthy.

The client uses source timestamps from backend responses and keeps `receivedAt`
separately. No source timestamp is fabricated. The selected presentation
threshold is **5 minutes** (`300000 ms`): this is conservative for the existing
manual/periodic read cadence and is client policy, not backend truth.

Accepted valid responses replace a bounded in-memory last-known-good snapshot.
There is no disk persistence. A transport, malformed, or incompatible-version
failure keeps the prior snapshot visible when one exists and marks it stale
with the latest bounded error category. With no prior snapshot, the client
shows unavailable, malformed, or unsupported-version state directly.

Cached state is never used to authorize an action; this client has no runtime
actions.

## Polling and diagnostic context

Polling uses one centralized `POLL_INTERVAL_MS=30000` cadence. A cycle starts
only after the previous cycle finishes; a failed cycle schedules the next
bounded attempt rather than spinning. Manual Refresh starts an immediate cycle.
Unmount cancels the cycle and its request.

Non-secret diagnostic context includes client/build version, target, supported
API major, source timestamp, received timestamp, freshness, and bounded error
category. It excludes credentials, private keys, UUID secrets, unrestricted
evidence, and registration material.

`RUNTIME_CHANGED=FALSE`, `SERVER_CHANGED=FALSE`, and
`PRODUCTION_NETWORK_CHANGED=FALSE` are hard acceptance boundaries.
