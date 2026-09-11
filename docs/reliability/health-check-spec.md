# Health Check Specification

**Related design:** [P12-001 Reliability Layer PRD](reliability-layer-prd.md)
**Status:** Design only; no probe is implemented by this specification.

## 1. Contract

One health run evaluates a single `(node_id, endpoint_id, vantage_id)` tuple. The run is an ordered set of stage probes with a common `run_id`. A stage is never reported `PASS` merely because a later stage succeeds.

Recommended initial cadence for an implementation review:

| Item | Target value | Interpretation |
|---|---:|---|
| Scheduled interval | 30 s | Frequency of a normal run; approval still required. |
| Per-stage timeout | 3,000 ms | Includes connection/handshake deadline for that stage. |
| Attempts per stage | 1 normal + at most 1 bounded retry | Retry must carry a new `attempt_id`; it cannot erase the first result. |
| Window | 5 min and 1 h | Short incident detection plus trend context. |
| Clock | UTC ISO-8601 plus monotonic duration | Wall-clock jumps must not corrupt latency. |

These are design defaults, not deployed configuration or an assertion of current production SLOs.

## 2. Probe stages

### 2.1 TCP reachability probe

**Purpose:** establish whether the vantage can complete a TCP connection to the approved Reality endpoint.

**Inputs:** endpoint hostname/IP, TCP port (normally 443), address family policy, timeout, and `probe_config_version`.

**Outputs:**

- `tcp_result`: `PASS`, `TIMEOUT`, `REFUSED`, `UNREACHABLE`, `DNS_ERROR`, or `ERROR`;
- `tcp_connect_latency_ms` when a connection completes;
- resolved address family and endpoint identity;
- error code/category without raw credentials or payload.

Do not call a timeout a TLS/Reality failure: no TLS evidence exists if TCP did not complete.

### 2.2 TLS/Reality probe

**Purpose:** establish that the approved client-side Reality handshake completes after TCP.

**Inputs:** a redacted test profile reference, expected server-name/short-id fingerprints as non-secret identifiers, timeout, and client/probe version.

**Outputs:**

- `reality_result`: `PASS`, `TIMEOUT`, `TLS_ALERT`, `IDENTITY_MISMATCH`, `PROTOCOL_ERROR`, or `ERROR`;
- `tls_handshake_latency_ms`;
- negotiated protocol metadata that is safe to record;
- `failure_detail_code` suitable for classification.

Private keys, UUIDs, full URLs, and reusable client profiles are evidence-store exclusions.

### 2.3 HTTP application probe

**Purpose:** prove that the connected path can complete the expected application transaction.

**Inputs:** an approved small endpoint, method, expected status set, payload limit, timeout, and a correlation token that contains no user data.

**Outputs:**

- `http_result`: `PASS`, `TIMEOUT`, `DNS_ERROR`, `CONNECT_ERROR`, `HTTP_STATUS_ERROR`, `TLS_ERROR`, or `TRANSFER_ERROR`;
- `http_status_code` when a response exists;
- `dns_latency_ms`, `ttfb_ms`, `http_total_latency_ms`, and bounded transfer bytes;
- response-size and content-integrity result if the target contract requires it.

HTTP success cannot repair a failed TCP or Reality stage; the run remains degraded or failed at the failed stage.

### 2.4 Independent latency sample

When an independent RTT mechanism is available, take a bounded sample set and record `rtt_samples`, `rtt_p50_ms`, `rtt_p95_ms`, `packet_loss_pct`, and `jitter_ms`. If the mechanism is unavailable, use `UNAVAILABLE`; never substitute `http_total_latency_ms` for RTT.

## 3. Result state model

| State | Meaning |
|---|---|
| `PASS` | The stage completed its contract within the deadline. |
| `FAIL` | The stage was attempted and its contract was not met. |
| `UNAVAILABLE` | The measurement could not be made because the required probe or vantage was absent. |
| `UNKNOWN` | The record is malformed, incomplete, or cannot be safely interpreted. |

Run-level state is the worst applicable stage state with this precedence: `UNKNOWN` > `FAIL` > `UNAVAILABLE` > `PASS`. A policy engine may additionally label `DEGRADED` when success is below threshold without every attempt failing.

## 4. Intermittent timeout handling

An isolated timeout is retained as an event and contributes to a rolling failure rate. It becomes an alert candidate only when the alert policy's count, percentage, or consecutive-failure threshold is met. The first timeout, retry outcome, neighboring runs, endpoint identity, and vantage must remain visible together.

The P11 observation “intermittent TCP timeout” is therefore initially classified as `TCP_FAILURE / TIMEOUT`, pending corroboration. It must not be promoted to `REALITY_FAILURE` or `HTTP_FAILURE` without a completed TCP connection and corresponding evidence.

## 5. Evidence requirements

Every attempt records:

```text
run_id, attempt_id, node_id, endpoint_id, vantage_id,
probe_config_version, started_at, duration_ms,
stage, result, error_class, error_detail_code,
metric_record_id, evidence_record_id
```

The evidence record additionally stores redacted target identity, resolved address family, tool/probe version, and retention class. It may include bounded diagnostic text; it must not include secrets, private keys, complete client configuration, or user payloads.

## 6. Alert inputs

The Alert Layer evaluates windows over normalized attempts. Initial policy inputs are:

- stage success rate and consecutive failures;
- timeout/refusal/error mix;
- latency p50/p95 and jitter;
- packet loss where measured;
- health score and score confidence/sample count;
- whether failures are isolated to one endpoint or vantage.

No alert may be raised solely from a missing metric without labeling it `UNAVAILABLE` or `UNKNOWN`.
