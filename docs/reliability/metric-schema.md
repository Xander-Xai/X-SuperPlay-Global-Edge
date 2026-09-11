# Reliability Metric Schema

**Related design:** [P12-001 Reliability Layer PRD](reliability-layer-prd.md)
**Status:** Proposed schema; no collector or storage migration is included.

## 1. Schema rules

- Names are `snake_case`; durations are milliseconds; rates are percentages in `[0,100]`; byte rates are bytes per second.
- Every record carries `observed_at` (UTC), `run_id`, `attempt_id`, `node_id`, `endpoint_id`, `vantage_id`, and `schema_version`.
- `MEASURED` means directly observed by the probe; `DERIVED` means calculated from measured values; `UNAVAILABLE` means the probe/source was not present; `UNKNOWN` means malformed or uninterpretable.
- A null numeric value must have a companion `*_status` or record-level status; null is never silently treated as zero.
- High-cardinality data (raw error text, request IDs, and full addresses) belongs in evidence, not metric labels.

## 2. Required identity and status fields

| Field | Type/unit | Status/source |
|---|---|---|
| `schema_version` | string | Schema contract version. |
| `run_id` | string | Health Agent run identity. |
| `attempt_id` | string | Unique stage attempt identity. |
| `observed_at` | timestamp | UTC wall-clock observation time. |
| `duration_ms` | number | Monotonic attempt duration. `MEASURED`. |
| `node_id` | string | Logical node; single-node in P12. |
| `endpoint_id` | string | Stable redacted endpoint identity. |
| `vantage_id` | string | Client/measurement location identity. |
| `stage` | enum | `tcp`, `reality`, `http`, `latency`. |
| `result` | enum | `PASS`, `FAIL`, `UNAVAILABLE`, `UNKNOWN`. |
| `metric_status` | enum | `MEASURED`, `DERIVED`, `UNAVAILABLE`, `UNKNOWN`. |
| `failure_class` | enum/string | See `failure-classification.md`; absent on a clean pass. |
| `evidence_record_id` | string | Pointer to raw/redacted evidence. |

## 3. TCP metrics

| Field | Type/unit | Definition |
|---|---|---|
| `tcp_attempts` | integer | Attempts in the aggregation window. `DERIVED` for windows. |
| `tcp_successes` | integer | Completed TCP connects. |
| `tcp_success_rate_pct` | number/% | `tcp_successes / tcp_attempts * 100`. |
| `tcp_connect_latency_ms` | number/ms | Time to completed TCP connect. `MEASURED` per attempt. |
| `tcp_timeout_count` | integer | Connect attempts exceeding deadline. |
| `tcp_refused_count` | integer | Explicit connection refusals. |
| `tcp_error_count` | integer | Other connect errors. |

## 4. Reality/TLS metrics

| Field | Type/unit | Definition |
|---|---|---|
| `reality_attempts` | integer | Attempts after TCP completion. |
| `reality_successes` | integer | Completed approved Reality handshakes. |
| `reality_success_rate_pct` | number/% | Successes divided by attempts. |
| `tls_handshake_latency_ms` | number/ms | TCP-connected to completed handshake. |
| `reality_timeout_count` | integer | Handshake deadline exceeded. |
| `reality_identity_mismatch_count` | integer | Expected non-secret identity did not match. |
| `tls_alert_count` | integer | TLS alert/negotiation failures. |

## 5. HTTP metrics

| Field | Type/unit | Definition |
|---|---|---|
| `http_attempts` | integer | Application probes attempted after Reality success. |
| `http_successes` | integer | Responses meeting the endpoint contract. |
| `http_success_rate_pct` | number/% | Successful responses divided by attempts. |
| `http_status_code` | integer | Response code for one attempt; not a label. |
| `dns_latency_ms` | number/ms | DNS phase timing when measured. |
| `ttfb_ms` | number/ms | Time to first response byte. |
| `http_total_latency_ms` | number/ms | Complete bounded HTTP transaction. |
| `http_transfer_bytes` | integer | Bytes transferred by the probe. |
| `http_transfer_bps` | number | Derived transfer rate; not TCP throughput. |

## 6. Latency and availability metrics

| Field | Type/unit | Definition |
|---|---|---|
| `rtt_samples` | integer | Independent RTT sample count. |
| `rtt_p50_ms` / `rtt_p95_ms` | number/ms | Percentiles from independent RTT samples only. |
| `packet_loss_pct` | number/% | Failed RTT probes divided by attempted samples. |
| `jitter_ms` | number/ms | Mean absolute delta between successive RTT samples. |
| `availability_pct` | number/% | Successful contract-compliant runs / eligible runs in a window. |
| `health_score` | number/[0,100] | Weighted score defined in the PRD. |
| `health_score_confidence` | enum | `HIGH`, `MEDIUM`, `LOW`, or `UNKNOWN` based on sample sufficiency. |
| `window_start` / `window_end` | timestamp | Aggregation window bounds. |

`tcp_connect_latency_ms`, `tls_handshake_latency_ms`, and `http_total_latency_ms` are separate phases. They must not be merged into an invented “RTT” field. Existing G1 v2 fields such as `tcp_retransmits` and server/kernel counters remain `UNAVAILABLE` until an approved server-side collector exists.

## 7. Example record

```json
{
  "schema_version": "p12.reliability.v1",
  "run_id": "run-20260908T120000Z-0042",
  "attempt_id": "attempt-0042-tcp-0",
  "observed_at": "2026-09-08T12:00:00.421Z",
  "duration_ms": 3001,
  "node_id": "edge-current",
  "endpoint_id": "reality-primary",
  "vantage_id": "windows-isolated-canary",
  "stage": "tcp",
  "result": "FAIL",
  "metric_status": "MEASURED",
  "tcp_connect_latency_ms": null,
  "failure_class": "TCP_FAILURE",
  "error_detail_code": "CONNECT_TIMEOUT",
  "evidence_record_id": "ev-0042-tcp-0"
}
```

The example records an observed timeout; it does not claim that a production alert or recovery action was taken.
