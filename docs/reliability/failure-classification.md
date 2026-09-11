# Failure Classification

**Related design:** [Health Check Specification](health-check-spec.md)
**Status:** Proposed taxonomy; classification is not implemented by P12-001.

## 1. Classification rules

Classification is assigned after the raw attempt is stored. It answers “which contract failed?” rather than asserting root cause. The first failed stage is the primary class; later stages that were not attempted are `NOT_RUN`, not failures.

Stage precedence:

```text
TCP_FAILURE -> REALITY_FAILURE -> HTTP_FAILURE
```

If a failure cannot be mapped safely, use `UNKNOWN_FAILURE` and retain the raw evidence for review.

## 2. Primary classes

### 2.1 `TCP_FAILURE`

The TCP contract did not complete.

| Code | Meaning | Typical evidence |
|---|---|---|
| `CONNECT_TIMEOUT` | Deadline expired before connect. | TCP attempt, timeout, endpoint, vantage. |
| `CONNECTION_REFUSED` | Peer or intermediary rejected connect. | OS error and timestamp. |
| `NETWORK_UNREACHABLE` | Local route/address-family failure. | Address family and route error. |
| `DNS_RESOLUTION_ERROR` | Endpoint name could not resolve. | Resolver result/error. |
| `TCP_RESET` | Connection reset before stage completion. | Socket error and phase. |

The P11 intermittent timeout observation maps to `TCP_FAILURE / CONNECT_TIMEOUT` until repeated evidence shows a different stage.

### 2.2 `REALITY_FAILURE`

TCP completed, but the TLS/Reality contract did not.

| Code | Meaning | Typical evidence |
|---|---|---|
| `REALITY_TIMEOUT` | Handshake exceeded deadline. | TCP pass plus handshake timing. |
| `TLS_ALERT` | TLS negotiation emitted an alert. | Redacted alert category. |
| `IDENTITY_MISMATCH` | Expected non-secret identity mismatch. | Fingerprint/short-id reference, never key material. |
| `PROTOCOL_ERROR` | Handshake framing/version contract failed. | Client/probe version and code. |

Do not classify a TCP timeout as `REALITY_FAILURE`; there is no handshake evidence.

### 2.3 `HTTP_FAILURE`

TCP and Reality completed, but the application contract did not.

| Code | Meaning | Typical evidence |
|---|---|---|
| `HTTP_TIMEOUT` | Response or transfer deadline expired. | DNS/connect/TTFB/total timings. |
| `HTTP_STATUS_ERROR` | Response status outside approved set. | Status code and target contract. |
| `HTTP_TRANSFER_ERROR` | Response body or transfer failed. | Bounded transfer details. |
| `HTTP_TLS_ERROR` | Application TLS failed after path establishment. | Redacted TLS error category. |
| `HTTP_DNS_ERROR` | Application target resolution failed. | Resolver evidence. |

## 3. Secondary labels and composite states

Secondary labels may describe `INTERMITTENT`, `CONSECUTIVE`, `LATENCY_DEGRADED`, `PACKET_LOSS_DEGRADED`, or `SCOPE_SINGLE_VANTAGE`. They do not replace the primary class.

Use `COMPOSITE_DEGRADED` for a window containing multiple primary classes, for example TCP timeouts plus HTTP timeouts. The window must retain counts by primary class so an aggregate cannot hide stage ordering.

Use `NO_DATA` when no eligible probe ran. Use `UNKNOWN_FAILURE` for malformed or contradictory records.

## 4. Diagnostic matrix

| TCP | Reality | HTTP | Classification | Interpretation boundary |
|---|---|---|---|---|
| Fail | Not run | Not run | `TCP_FAILURE` | Transport reachability failed; do not infer Reality cause. |
| Pass | Fail | Not run | `REALITY_FAILURE` | TCP path works for this attempt; handshake contract failed. |
| Pass | Pass | Fail | `HTTP_FAILURE` | Path established; application contract failed. |
| Pass | Pass | Pass | No failure | One successful run only; not a stability claim. |
| Mixed over window | Mixed | Mixed | `COMPOSITE_DEGRADED` | Investigate per-attempt and per-vantage evidence. |

## 5. Evidence required before root-cause claims

At minimum, a root-cause hypothesis must include:

1. raw attempts and stage outcomes for the affected window;
2. endpoint, node, and vantage identity;
3. timing and error-code distribution;
4. comparison with a healthy neighboring window or independent vantage when available;
5. explicit statement of what remains unproven.

“Server is healthy,” “one TCP connection succeeded,” or “HTTP returned 200 once” is not sufficient evidence to clear an incident.
