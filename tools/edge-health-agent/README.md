# Edge Health Agent (P12-002 / P12-003 / P12-004)

Standalone, one-shot, read-only health observation for X-SuperPlay Global Edge. It emits one JSON evidence document containing a TCP probe, configured HTTP probes, an optional public-egress comparison, and a bounded health score.

This tool does not start a service, change a route, restart anything, or modify a client/server configuration.

## Usage

From this directory:

```powershell
python probe.py --config config.example.yaml
```

The JSON evidence is written to stdout. To also save the same document to a file:

```powershell
python probe.py --config config.example.yaml --output evidence.json
```

Probe failures are represented in the JSON result; a successfully executed observation run still exits with code `0`. Invalid configuration or an unreadable output path exits non-zero.

To persist the result and refresh the local summary, use the evidence flag:

```powershell
python probe.py --config config.example.yaml --output-evidence
```

This writes `evidence/YYYY-MM-DD/probe-YYYYMMDDTHHMMSS.json` and
`evidence/summary.json`. A custom evidence directory can be supplied after the
flag, for example `--output-evidence .\run-evidence`.

After evidence has been summarized, evaluate the local alert rules without
running any network probe:

```powershell
python probe.py --evaluate-alert --config config.example.yaml
```

When run from this directory, `--config` may be omitted. The command reads the
configured `summary_path` and writes `alert.json` to `output_path`.

## Configuration

`config.example.yaml` contains the complete shape:

- `timeout_seconds`: bounded timeout applied to each network operation.
- `tcp.host` / `tcp.port`: one TCP connect target. The socket is closed immediately after connect.
- `http.targets`: named HTTPS/HTTP GET targets and their accepted status codes. Each target is recorded independently.
- `egress.enabled`: when `true`, query `egress.url` and compare the returned IP with `egress.expected_ip`.
- `egress.proxy`: optional HTTP(S) proxy URL used only by the egress request.
- `evidence.root`: local evidence directory, defaulting to `evidence`.
- `evidence.max_days`: retention window in days, defaulting to `7`; cleanup uses probe-file mtime.
- `alerts.summary_path` / `alerts.output_path`: input summary and deterministic alert output paths.
- `alerts.success_rate_threshold`: warning threshold, default `99` percent.
- `alerts.p95_latency_threshold_ms`: warning threshold, default `3000` milliseconds.
- `alerts.tcp_failure_threshold`: critical threshold, default `3` failures; the rule fires only when the count is above it.

The egress endpoint may return a plain IP or common JSON fields such as `ip`, `origin`, `address`, `public_ip`, or `query`. Do not place proxy credentials or other secrets in evidence-producing configuration that will be committed.

## Evidence and score

The output has this stable top-level shape:

```json
{
  "schema_version": "p12.health-probe.v1",
  "timestamp": "2026-09-08T12:00:00.000Z",
  "tcp": {},
  "http": {},
  "egress": {},
  "health_score": 0
}
```

`probe.py` validates every generated document against its embedded JSON Schema before output. TCP contributes 40 points, HTTP contributes 40 points weighted by successful targets, and configured egress contributes 20 points when enabled. Disabled egress and an empty HTTP target list are excluded from the denominator; the score is a diagnostic summary, not an SLO or an alert.

The summary treats each evidence file as one check. `success_rate` is a
percentage from 0 to 100. `tcp_failures` counts failed TCP checks;
`http_failures` counts failed HTTP targets. Average and p95 latency use every
non-null TCP/HTTP `latency_ms` value, including failed attempts. Malformed or
schema-invalid probe files are excluded and reported as
`corrupted_evidence_count`.

Alert evaluation checks critical TCP failures first, then warning success rate,
then warning p95 latency. A healthy summary still produces an `alert.json` with
`level: NONE`; this makes the result auditable and reproducible. Alert output is
local only: there are no notification integrations, automatic recovery, node
switching, daemon mode, Prometheus, or Grafana.

## Tests

Install the declared dependencies in an isolated environment, then run:

```powershell
python -m unittest discover -s tests -v
```

The tests mock socket/HTTP operations, cover timeout and network failures, verify egress matching, validate a complete evidence object against JSON Schema, and cover evidence creation, summary, retention, and corrupted-file handling. No test contacts the public Internet.

## Limitations and explicit non-goals

- This MVP checks TCP reachability only; it does **not** implement a TLS/Reality handshake probe.
- It is a one-shot CLI; there is no daemon or scheduled mode.
- It has no alerting, Prometheus, Grafana, automatic recovery, node switching, or failover.
- It does not modify Xray, WireGuard, Docker Compose, deployment scripts, runtime files, VPS state, or server configuration.
- HTTP status and latency are endpoint observations, not a proof of long-run availability, throughput, packet loss, or path stability.
- Egress comparison is optional and depends on the configured echo endpoint and expected IP; an unavailable or misconfigured egress check is recorded rather than guessed.
