# Recovery Policy

**Related design:** [P12-001 Reliability Layer PRD](reliability-layer-prd.md)
**Status:** Policy design only; no automatic recovery or traffic change is implemented.

## 1. Policy intent

Recovery decisions must be evidence-gated. The reliability layer observes and recommends a response; an authorized operator or a later approved controller performs any production mutation. This separation prevents a noisy probe from causing an unreviewed restart, failover, or client change.

## 2. Recovery levels

| Level | Entry condition (design target) | Required output | Allowed action in P12 |
|---|---|---|---|
| `R0_OBSERVE` | Healthy or insufficient evidence. | Normal metric/evidence record. | Continue observation. |
| `R1_WARN` | A rolling threshold is crossed, but scope/severity is limited. | Alert with class, counts, score, and evidence links. | Manual investigation only. |
| `R2_ISOLATE` | Repeated classified failure or a hard safety condition for one path. | Endpoint/path marked `DEGRADED` or `INELIGIBLE` with expiry and reason. | Record recommendation; do not steer traffic automatically. |
| `R3_INCIDENT` | Broad, sustained, or security-significant impact. | Incident record, timeline, owner, and approved recovery plan. | Operator-approved runbook only; post-change verification required. |

Suggested design thresholds (to be tuned with production baseline):

- `R1`: at least 2 failed attempts in a 5-minute window or success below the approved warning rate;
- `R2`: 3 consecutive failures, or a hard identity/protocol mismatch, with corroborating evidence;
- `R3`: impact across two consecutive windows, multiple vantages, or an approved criticality trigger.

Thresholds are not implementation and must not be treated as current SLOs.

## 3. Hysteresis and cooldown

- Entering a level requires the entry threshold and minimum sample count.
- Leaving `R1`/`R2` requires a separate recovery threshold, such as two consecutive healthy windows, not one passing probe.
- A recovery recommendation has a cooldown so repeated alerts do not generate repeated actions.
- A new failure during cooldown extends the evidence window and reopens review; it does not silently reset history.
- All threshold evaluations record the policy version and sample sufficiency.

## 4. Evidence-gated decision workflow

```text
raw attempts
  -> normalize and classify
  -> verify sample sufficiency
  -> compare rolling windows and independent vantages
  -> assign R0/R1/R2/R3
  -> create alert or incident record
  -> operator reviews evidence
  -> approved action (future implementation only)
  -> repeat probes
  -> record post-action verification and close/keep open
```

The evidence bundle for a recovery decision includes the triggering records, neighboring healthy records, threshold/policy version, operator/change identifier, and post-action probe results. Sensitive configuration and secrets are excluded.

## 5. Failure-specific guidance

### TCP failure

First compare endpoint, address family, and vantage. Repeated `CONNECT_TIMEOUT` across independent vantages suggests a broader path or endpoint incident; a single-vantage timeout remains scoped until corroborated. Do not change Reality or WireGuard configuration as part of observation.

### TLS/Reality failure

Confirm that TCP passed in the same attempt, then inspect handshake error code and non-secret identity references. An identity mismatch is a high-severity review trigger, not permission for automatic key or config rotation.

### HTTP failure

Separate target DNS, status, TTFB, transfer, and total latency. An HTTP endpoint outage must not be reported as a transport outage without corresponding TCP/Reality failures.

## 6. Future automation boundary

A later implementation may map `R2` or `R3` to a manually approved runbook, but must add:

- idempotency and lock ownership;
- change authorization and audit trail;
- bounded retries and rollback criteria;
- protection against alert storms and split-brain decisions;
- mandatory post-change evidence.

P12-001 deliberately adds none of these runtime actions.

## 7. Future multi-node extension

Recovery state must be keyed by `node_id + endpoint_id + vantage_id`, then aggregated for a fleet view. A node may be isolated without declaring the entire service unavailable. Future selection or failover must use the same per-node evidence contract, preserve node-specific alerts, and require an independently approved multi-node policy. No multi-node deployment or automatic failover is part of this task.
