# 公开验收标准

本文只保留可公开的验收层次；真实服务器地址、时间戳、吞吐量和客户端身份不在公开仓库保存。

| 层次 | 证明内容 |
|---|---|
| L0 配置 | 必填变量、镜像身份和端口策略符合契约 |
| L1 控制面 | Docker、服务健康检查和 loopback 管理面可用 |
| L2 WireGuard | 接口、监听端口、peer 和握手状态可读 |
| L3 真实客户端 | 端点身份、MTU、DNS、完整负载和出口身份分别通过 |

安装成功、一次握手、单个 HTTP 状态或服务器本身健康，都不能替代 L3 真实客户端验收。

## G1 v2 reliability gates

The additive migration adds evidence layers without weakening L0-L3:

| Gate | Required evidence | Current state |
| --- | --- | --- |
| Segmented baseline | Windows public/WireGuard/route-isolated probes, PMTU, VPS egress and kernel counters | `BLOCKED` until external runtimes are available |
| Protocol ABC | Same Windows, same VPS, same targets: WireGuard UDP/51820, Hysteria2 UDP/443, Reality TCP/443 | `BLOCKED` |
| Application reliability | Mihomo `GLOBAL-STABLE` health checks, fallback <=30s, recovery <=2 intervals | `BLOCKED` |
| Time-based soak | JSONL connection-age metrics at T0/15m/1h/3h/6h/12h/24h/72h/7d | `NOT_YET_ELAPSED` |

The immutable SLOs remain success >=99%, no five consecutive failures, p95
latency bounded relative to T0, throughput >=70% of T0, controlled loss <=1%,
and normal unloaded jitter <=50ms. See `scripts/g1-v2-soak.ps1` and the public
[`g1-v2-resilient-global-edge-prd.md`](g1-v2-resilient-global-edge-prd.md).
