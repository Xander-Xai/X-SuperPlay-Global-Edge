# P12-001 Reliability Layer PRD

**Status:** Design only

**Repository:** X-SuperPlay-Global-Edge

**Phase:** P12-001
**Authority:** Reliability-layer target design; it does not change the current implementation status in `PROJECT-ROADMAP.md` or `docs/architecture.md`.

## 1. Purpose

P11 established that the Reality path can be validated end to end: the Reality runtime, TCP/443 reachability, an isolated Windows Reality client, and Internet egress all passed. P11 also observed intermittent TCP timeouts. A process-alive check or one successful connection is therefore insufficient for production reliability decisions.

This document defines the production reliability observability layer that would measure, classify, preserve evidence for, and escalate those events. It is a design contract only; implementation and deployment require a later authorized change.

## 2. Goals

The layer shall:

1. Observe the path in independently testable stages: TCP, TLS/Reality, HTTP, and end-to-end latency/availability.
2. Keep raw observations and derived decisions traceable to the same probe attempt.
3. Distinguish transport failure from Reality handshake failure and application failure.
4. Detect intermittent failure without turning a single timeout into an outage.
5. Produce an auditable health score and an evidence bundle for every alert or recovery decision.
6. Support a later multi-node view without requiring a protocol or client rewrite.

## 3. Non-goals and hard boundary

P12-001 does **not**:

- **No protocol change:** no protocol, port, cipher, Reality identity, or routing design is changed.
- **No client rewrite:** no client is rewritten or reconfigured.
- **No multi-node deployment:** no multi-node topology is deployed.
- **No automatic recovery implementation:** no automatic recovery, failover, restart, or traffic steering is implemented.
- modify Xray, WireGuard, Docker Compose, runtime files, server state, or CI;
- claim that the design is running or that an SLO is currently met.

The only deliverable in this task is documentation.

## 4. Architecture

```text
                    Probe targets / client vantage
                              |
                              v
                       +--------------+
                       |  Health Agent |
                       +------+-------+
                              |
                              v
                       +--------------+
                       |  Probe Engine |
                       | TCP -> Reality|
                       | TLS -> HTTP   |
                       +------+-------+
                              |
             raw result + timing + identity + error class
                              |
              +---------------+----------------+
              v                                v
       +--------------+                  +-------------+
       | Metric       |                  | Evidence    |
       | Collector    |----------------->| Store       |
                       +------+-------+                  +------+------+
              |                                 |
              +----------------+----------------+
                               v
                        +--------------+
                        |  Alert Layer |
                        +--------------+
```

### 4.1 Health Agent

The Health Agent owns scheduling, probe identity, clock/time-zone normalization, and publication of a single run envelope. It must not infer health from a process status alone. Each run has a `run_id`, `node_id` (single-node in P12), `vantage_id`, `started_at`, software/schema version, and a monotonic sequence number.

### 4.2 Probe Engine

The Probe Engine executes ordered, bounded probes:

1. TCP connect to the approved Reality endpoint and port.
2. TLS/Reality handshake validation using the approved client test identity, without recording secrets.
3. HTTP transaction through the connected path, with status and transfer timing.
4. Optional independent unloaded latency samples when the vantage supports them.

Each stage reports `PASS`, `FAIL`, or `UNAVAILABLE`. A later-stage pass never masks an earlier-stage failure. Probe parameters are versioned and are data in the evidence bundle rather than implicit assumptions.

### 4.3 Metric Collector

The collector turns raw probe events into measured fields and explicitly marked derived fields. It must preserve the distinction used by existing G1 v2 metrics: RTT is not HTTP total time; unavailable server-side counters remain unavailable rather than being guessed.

### 4.4 Evidence Store

The store is append-only from the layer's point of view. It retains the raw event, normalized record, classification, and links between related attempts. It must support retrieval by `run_id`, time range, endpoint, and failure class. Secrets, private keys, full client profiles, and authorization material are never stored.

### 4.5 Alert Layer

The Alert Layer consumes classified windows, not single raw samples. It emits an alert containing the affected dimensions, threshold crossed, first/last occurrence, health score, and evidence references. Notification transport is intentionally unspecified in P12; alert delivery must not alter the data plane.

## 5. Operating principles

- **Evidence first:** capture raw result and timing before classification or notification.
- **Stage isolation:** TCP, Reality, and HTTP have independent outcomes.
- **No false precision:** use `UNAVAILABLE`/`UNKNOWN` when a measurement cannot be made.
- **Hysteresis:** alert and recovery thresholds are different to prevent flapping.
- **Bounded probes:** every probe has a timeout, retry budget, and deadline.
- **Stable identity:** endpoint, target, vantage, and schema versions are explicit labels.
- **Privacy by design:** no secrets or sensitive payloads in metrics or evidence.

## 6. Health score model

The score is a bounded diagnostic signal, not a replacement for raw metrics or acceptance gates.

For a scoring window `W`, calculate component scores only from measured observations:

```text
S_tcp     = 100 * tcp_successes / tcp_attempts
S_reality = 100 * reality_successes / reality_attempts
S_http    = 100 * http_successes / http_attempts
S_latency = clamp(100 * (1 - p95_latency / latency_budget_ms), 0, 100)
```

The composite score is:

```text
health_score = 0.30*S_tcp + 0.30*S_reality + 0.25*S_http + 0.15*S_latency
```

The score is `UNKNOWN` when fewer than the minimum sample count for any required component is available. A hard stage failure remains visible even if the weighted score stays above an alert threshold. The exact window, sample minimums, and latency budget are configuration to be approved with implementation; this PRD does not silently set production SLOs.

## 7. Evidence-first workflow

```text
schedule run
  -> create run envelope
  -> execute bounded stage probes
  -> persist raw observations
  -> normalize metric record
  -> classify failure(s)
  -> compute score/window state
  -> evaluate alert policy
  -> emit alert with evidence references
  -> retain for review and later recovery decision
```

An alert is not proof of root cause. Root-cause statements require corroborating evidence from the same window and, where relevant, an independent vantage or server-side observation.

## 8. Recovery levels (policy target)

The design uses four levels; P12 defines their evidence requirements only.

| Level | Meaning | Design response |
|---|---|---|
| R0 | Observe | Continue probes; no operator action. |
| R1 | Warn/degraded | Notify with classified evidence; inspect trend and scope. |
| R2 | Isolate | Mark the affected endpoint/path ineligible for a future decision and request manual validation; do not change traffic automatically. |
| R3 | Incident/recovery decision | Require an operator-approved recovery runbook, change record, and post-change verification. |

Automatic restart, failover, rollback, or client mutation is outside this deliverable. A later implementation may map these levels to actions only after explicit authorization and safety review.

## 9. Future multi-node extension

The single-node design reserves `node_id`, `region`, `provider`, `vantage_id`, and `endpoint_id` dimensions. A later multi-node implementation could compare the same probe contract across nodes, calculate regional availability, and select a node using an independently approved policy. It must preserve per-node evidence and must not hide a node-specific failure in an aggregate. No multi-node service, scheduler, consensus, or deployment is created by P12-001.

## 10. Acceptance for this documentation task

P12-001 is accepted when:

- the five reliability documents exist under `docs/reliability/`;
- terms and field meanings are consistent across the documents;
- no runtime, compose, Xray, WireGuard, CI, server, or deployment file is changed;
- the documents clearly distinguish design intent from observed P11 evidence and implemented state.
