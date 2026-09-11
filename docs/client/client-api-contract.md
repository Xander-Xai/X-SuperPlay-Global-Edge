# X-SuperPlay Edge Read-Only Observation API Contract

**Status:** Read-only contract for P13-001, aligned and hardened by P13-003.

**API version:** `v1`

**Base path:** `/api/v1`

This document describes the existing read-only state/reliability API as
consumed by the desktop observer. Every endpoint in this contract is `GET`
only. The client must not
assume that a successful HTTP response means the data plane is healthy; it
must inspect the returned state and timestamp.

## 1. Transport and common rules

- Use HTTPS in a deployed environment; local development may bind to a
  loopback address as already documented by the API service.
- Send `Accept: application/json` for JSON resources and
  `Accept: text/plain; version=0.0.4` for `/metrics`.
- Responses are UTF-8. JSON objects use the fields shown below; additive
  fields are allowed.
- A client should apply a bounded request timeout and retry only idempotent
  `GET` requests. It must not retry by mutating state because this contract
  has no mutation method.
- `timestamp` values are UTC ISO-8601 strings when present. `null` means that
  no valid observation exists, not that the observation succeeded.
- Unknown paths return `404`; a write attempt returns `405` with a
  `read_only` error payload.

### Error envelope

```json
{
  "error": "not_found|read_only|<bounded error code>"
}
```

Transport failures, malformed JSON, missing required fields, and unsupported
versions are client-side `unavailable`/`unknown` conditions. They are not
converted into a synthetic node failure.

## 2. Node resources

### `GET /api/v1/node/status`

Returns the unified read-only runtime snapshot.

```json
{
  "node_id": "edge-current",
  "overall_status": "healthy",
  "health_score": 100.0,
  "service_states": {
    "wireguard": {
      "name": "wireguard",
      "status": "unavailable",
      "reason": "service_state_not_present_in_local_evidence",
      "source": "local_evidence"
    },
    "xray_reality": {"name": "xray_reality", "status": "unavailable", "reason": "service_state_not_present_in_local_evidence", "source": "local_evidence"},
    "hysteria2": {"name": "hysteria2", "status": "unavailable", "reason": "service_state_not_present_in_local_evidence", "source": "local_evidence"}
  },
  "timestamp": "2026-09-08T12:00:00.000Z",
  "corrupted_evidence_count": 0
}
```

Required fields: `node_id` (string), `overall_status` (`healthy`,
`degraded`, or `unknown`), `health_score` (number or `null`),
`service_states` (object), `timestamp` (string or `null`), and
`corrupted_evidence_count` (non-negative integer). The score is read from the
existing evidence pipeline; the client must not recompute it.

### `GET /api/v1/node/identity`

Returns configuration-backed identity:

```json
{
  "node_id": "edge-current",
  "region": "unspecified",
  "provider": "unspecified",
  "version": "p12-007"
}
```

All four fields are non-empty strings. Identity is descriptive metadata, not
authentication and not proof that a service is running.

### `GET /api/v1/node/capabilities`

Returns configuration declarations for supported protocols:

```json
{
  "wireguard": false,
  "xray_reality": false,
  "hysteria2": false
}
```

Missing capability keys default to `false`. These booleans describe declared
support only; they are not service liveness or permission grants.

### `GET /api/v1/node/services`

Returns per-service declarations and observed availability:

```json
{
  "node_id": "edge-current",
  "services": {
    "wireguard": {"name": "wireguard", "status": "unavailable", "reason": "service_state_not_present_in_local_evidence", "source": "local_evidence"},
    "xray_reality": {"name": "xray_reality", "status": "unavailable", "reason": "service_state_not_present_in_local_evidence", "source": "local_evidence"},
    "hysteria2": {"name": "hysteria2", "status": "unavailable", "reason": "service_state_not_present_in_local_evidence", "source": "local_evidence"}
  },
  "timestamp": "2026-09-08T12:00:00.000Z",
  "corrupted_evidence_count": 0
}
```

`unavailable` is the expected value while the current evidence schema has no
service-manager observations. A capability declaration must not be promoted
to a runtime status.

### `GET /api/v1/node/connection`

Returns the observed connection projection from local evidence:

```json
{
  "node_id": "edge-current",
  "connection_state": "connected|failed|unknown",
  "protocol": "tcp_probe|unknown",
  "endpoint_metadata": {"host": "edge.example", "port": 443},
  "timestamp": "2026-09-08T12:00:00.000Z",
  "corrupted_evidence_count": 0
}
```

`node_id`, `connection_state`, `protocol`, `endpoint_metadata`,
`corrupted_evidence_count`, and `timestamp` are required fields; `timestamp`
is nullable. The current backend only derives this projection from the
existing TCP probe. It does not prove a WireGuard tunnel, Xray Reality
handshake, Hysteria2 session, route, DNS, or system-proxy state. Empty or
unavailable evidence is represented as `unknown`/nullable fields rather than
as a synthetic failure.

## 3. Health resources

### `GET /api/v1/health/current`

Returns the newest valid probe result as a presentation of existing evidence:

```json
{
  "node_status": "healthy",
  "health_score": 100.0,
  "latest_metrics": {
    "tcp": {"host": "edge.example", "port": 443, "success": true, "latency_ms": 20.0, "error": null},
    "http": {},
    "egress": {}
  },
  "timestamp": "2026-09-08T12:00:00.000Z",
  "corrupted_evidence_count": 0
}
```

With no valid evidence, `node_status` is `unknown`, `health_score` is `null`,
`latest_metrics` is empty, and the corrupted count remains visible.

### `GET /api/v1/health/history`

Returns the existing summary without recalculation in the client:

```json
{
  "availability": 100.0,
  "latency_percentiles": {"p95": 40.0},
  "historical_summary": {
    "total_checks": 1,
    "success_count": 1,
    "failure_count": 0,
    "success_rate": 100.0,
    "tcp_failures": 0,
    "http_failures": 0,
    "average_latency": 30.0,
    "p95_latency": 40.0
  }
}
```

`availability` and `success_rate` are percentages in `[0,100]`. The current
contract exposes p95 only; a missing percentile is unavailable, not zero.

## 4. Events and metrics

### `GET /api/v1/events`

Returns the current alert snapshot:

```json
{
  "events": [
    {
      "timestamp": "2026-09-08T12:00:00.000Z",
      "level": "WARNING",
      "reason": "success_rate below threshold",
      "metric": "success_rate",
      "value": 98.0,
      "threshold": 99.0,
      "source_evidence": "summary.json",
      "resolved": false
    }
  ],
  "resolved": false,
  "timestamp": "2026-09-08T12:00:00.000Z"
}
```

`level` is `WARNING`, `CRITICAL`, or `NONE`. A `NONE` snapshot returns an
empty `events` array and `resolved: true`; an invalid alert file is reported
as a bounded error and is not re-evaluated by the client.

### `GET /metrics`

This endpoint is outside the JSON base path and returns UTF-8 Prometheus text
exposition (`text/plain; version=0.0.4`). The adapter emits these label-free
gauges in deterministic order:

```text
x_superplay_health_score
x_superplay_http_success_rate
x_superplay_latency_p50_ms
x_superplay_latency_p95_ms
x_superplay_node_status
x_superplay_alert_count
```

The values come from existing API models. Rates are percentages; node status
is `1` for healthy, `0` for degraded, and `NaN` for unknown; unavailable
latency/score values are `NaN`. The current summary has no p50 field, so p50
is `NaN` until an upstream contract supplies it. The client may display or
forward these values but must not derive a second health score.

## 5. Client compatibility and security

- Treat every response as untrusted input and validate required fields before
  display.
- Do not persist raw credentials, private keys, full client profiles, or
  unrestricted evidence payloads.
- Keep any future token broker outside the UI process and outside logs.
- Do not expose API responses to third-party analytics without an explicit
  redaction and privacy review.
- Preserve `node_id`, timestamps, and source evidence references when caching
  so a user can distinguish current, stale, and unavailable state.
- No endpoint in this contract starts, stops, restarts, switches, rewrites, or
  repairs a runtime service.

## 6. P13-003 observer policy

- Requests are `GET` only, with a 5000 ms timeout and at most two total
  attempts. Only transport failures and HTTP 502/503/504 are retryable.
- JSON responses require `application/json` or a compatible `+json` media
  type. `/metrics` requires `text/plain` compatible with Prometheus
  exposition. A successful HTTP status with the wrong media type is malformed.
- The client supports API major `v1`, read from `/api/v1/node/metadata`.
  An explicitly incompatible major is shown as `UNSUPPORTED_API_VERSION`.
- Source timestamps are preserved. Freshness is `FRESH`, `STALE`, or
  `UNAVAILABLE` and is independent from runtime health. The desktop uses a
  five-minute presentation threshold and retains only an in-memory,
  last-known-good snapshot; it has no disk cache or runtime actions.
