# Edge Reliability API (P12-005 through P12-008)

Local, read-only HTTP interfaces over the existing edge-health evidence output. The service is intended as a stable backend seam for a future desktop client, dashboard, or mobile client. It does not probe the network, rewrite evidence, calculate a new health score, send notifications, or perform recovery.

## Run locally

From the repository root:

```powershell
python services/edge-health-api/app.py --host 127.0.0.1 --port 8080 --evidence-root tools/edge-health-agent/evidence
```

The default evidence root is `tools/edge-health-agent/evidence`. The server binds locally by default and can be stopped with `Ctrl+C`.

## Endpoints

| Method | Path | Response |
|---|---|---|
| GET | `/api/v1/health/current` | Latest valid probe, node status, score, metrics, timestamp. |
| GET | `/api/v1/health/history` | Existing summary availability, p95 latency, and full historical summary. |
| GET | `/api/v1/events` | Current warning/critical alert snapshot with resolved state. |
| GET | `/api/v1/node/status` | Unified node id, overall status, score, service states, and timestamp. |
| GET | `/api/v1/node/services` | WireGuard, Xray Reality, and Hysteria2 state entries. |
| GET | `/api/v1/node/connection` | Observed connection state, protocol marker, and endpoint metadata. |
| GET | `/api/v1/node/identity` | Configured node id, region, provider, and identity version. |
| GET | `/api/v1/node/capabilities` | Configured WireGuard, Xray Reality, and Hysteria2 declarations. |
| GET | `/api/v1/node/metadata` | Configured node, runtime, and API versions. |
| GET | `/metrics` | Deterministic Prometheus text snapshot of current reliability values. |

Unknown paths return `404`; POST returns `405` with `read_only`.

### Current health

The API reads the newest valid `probe-*.json`. With no valid evidence it returns `node_status: unknown`, a null score, empty metrics, and the corrupted-file count. A score of at least 99 is reported as `healthy`; lower valid scores are `degraded`. This is presentation only—the probe's score is not recalculated.

### History

`health/history` delegates to `EvidenceStore.summarize()`. `availability` is the existing percentage-valued `success_rate`; `latency_percentiles.p95` is the existing `p95_latency`. Corrupted evidence remains excluded and visible in `historical_summary.corrupted_evidence_count`.

### Alert events

`events` reads the existing `alert.json`. WARNING and CRITICAL snapshots are returned as one event with `resolved: false`. A `NONE` alert produces an empty event list with `resolved: true`; a missing alert file is treated as resolved/empty. Invalid alert JSON is reported as an error payload and is never invented or re-evaluated.

### Prometheus metrics

`GET /metrics` is a read-only text exposition endpoint. It emits the six
`x_superplay_*` gauges in a fixed order, using the existing health, runtime,
history, and alert route models. Unavailable values are exposed as `NaN`; an
empty or fully corrupted evidence store therefore does not become a false
zero. The current evidence summary has no p50 field, so
`x_superplay_latency_p50_ms` remains `NaN` until an existing upstream model
provides that observation. `x_superplay_node_status` is `1` for healthy, `0`
for degraded, and `NaN` when unknown. No Prometheus or Grafana service is
deployed by this adapter.

## Runtime state contract

The node endpoints are a read-only future data contract for desktop, Android,
and web clients. With the current evidence schema, `wireguard`, `xray_reality`,
and `hysteria2` are explicitly `unavailable` because no service-state evidence
exists; a successful TCP probe is never promoted to a Reality or tunnel state.
The connection protocol is therefore reported as `tcp_probe`, with the TCP
endpoint host/port as metadata. Empty evidence returns `unknown` node and
connection states while retaining an empty/unavailable service map.

## Identity configuration

Identity is loaded from `config/node.yaml` (or the path supplied with
`--identity-config`). `identity.node_id`, `region`, `provider`, and `version`,
plus `metadata.runtime_version` and `metadata.api_version`, are required
non-empty strings. The provider has no identity fallback or hardcoded node
value: a missing file, invalid YAML, or missing required field prevents server
startup. Capability keys default to `false` when omitted; `true` is only a
configuration declaration and does not prove runtime service health.

## Data and safety boundaries

- Reads `tools/edge-health-agent/evidence/` only; it never writes there.
- Reuses the existing `EvidenceStore` summary and alert schema; no duplicate health calculation exists in the API.
- Runtime state is derived from existing evidence only; the API does not add a service manager or runtime-state writer.
- Identity and capability responses are read-only configuration views; they do not authenticate clients or orchestrate nodes.
- No WireGuard, Xray, Docker, VPS, production configuration, notifications, UI, auto recovery, or node switching.
- This is a local API process, not a production deployment or authentication layer. Do not expose it beyond a trusted local boundary without a separately approved security design.

## Tests

```powershell
python -m unittest discover -s services/edge-health-api/tests -v
```

Tests start an ephemeral local HTTP server and use temporary evidence roots. They cover startup, response shape, empty/corrupted evidence, alert retrieval, Prometheus formatting and deterministic output, and the read-only method boundary. No external network is contacted.
