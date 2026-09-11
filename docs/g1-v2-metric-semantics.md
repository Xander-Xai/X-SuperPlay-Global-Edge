# G1 v2 metric semantics

The Windows soak runner records measured values separately from values that are derived or unavailable. It never substitutes an HTTP total time for network RTT.

| Field | Meaning | Source/status |
|---|---|---|
| `rtt_samples`, `rtt_p50_ms`, `rtt_p95_ms` | Independent ICMP samples and interpolated percentiles | `Test-Connection`, `MEASURED` only with more than one successful sample |
| `packet_loss_pct` | Failed RTT probes divided by attempted probes | `Test-Connection`; independent of HTTP success |
| `jitter_ms` | Mean absolute delta between successive RTT samples | Derived from RTT samples |
| `dns_latency_ms`, `tcp_connect_latency_ms`, `tls_latency_ms`, `ttfb_ms`, `total_latency_ms` | Curl HTTP transaction timings | `curl transfer timings` |
| `http_transfer_bps` | Curl download transfer rate | `curl transfer timings`; not TCP throughput |
| `tcp_throughput_bps`, `tcp_retransmits` | Host/server TCP counters | `null`, `UNAVAILABLE`; requires server-side collector |
| `controlled_udp_loss_pct` | Controlled UDP loss result | `null`, `UNAVAILABLE`; requires protocol probe |
| `wg_latest_handshake_age_s`, `wg_rx_bytes`, `wg_tx_bytes` | WireGuard server state | `null`, `UNAVAILABLE`; requires server-state collector |
| `cpu_pct`, `softirq`, `conntrack_count`, `conntrack_max`, `udp_receive_errors`, `udp_send_errors`, `nic_rx_drops`, `nic_tx_drops` | Server/kernel counters | `null`, `UNAVAILABLE`; requires `g1-v2-server-state.sh` |
| `ram_available_bytes` | Local Windows free physical memory | `Win32_OperatingSystem`, `MEASURED` when available |
| `http_204_latency_ms` | Dedicated HTTP 204 probe | `null`, `UNAVAILABLE` until a dedicated 204 target is configured |

`soak_session_id` and `soak_started_at` are persistent session metadata. A resume rejects malformed JSONL, mixed session metadata, or a decreasing `connection_age_s`; it does not reset age to the resume time.
