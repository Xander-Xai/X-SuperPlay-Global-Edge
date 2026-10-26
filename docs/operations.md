# 公开运维说明

本文件提供不含真实资产标识的运维原则。生产主机、端口暴露、链路结果和恢复命令保存在私有运营资料中。

## 日常检查

```bash
bash scripts/healthcheck.sh <env-file>
bash scripts/wireguard-check.sh <env-file>
bash scripts/p8-check.sh <env-file>
```

所有检查都必须使用显式配置文件；缺失配置、状态不确定或端点身份不一致时应失败关闭。

## 端点与出口

客户端接入端点与 VPN 出口身份是两个独立事实。公开文档只使用占位符，不记录真实公网 IP、内网网段或客户端名称。实际值应从受控配置和私有资产记录读取。

## 故障处理

先保留原始日志和测量结果，再判断是主机、协议、MTU/PMTU、DNS 还是跨网络路径问题。不要因为握手成功或 HTTP 状态正常就宣称真实客户端链路可用。

## G1 v2 read-only discovery and evidence

Before any additive runtime mutation, collect:

```bash
bash scripts/g1-v2-server-state.sh .temp/g1-v2-server-state-T0.json T0
bash scripts/g1-v2-validate.sh
```

On the real Windows client, collect route/TUN/DNS/MTU state with
`scripts/g1-v2-windows-state.ps1`. Keep raw output in the approved private
evidence boundary. Repeat the server-state collector at a degraded observation
as `DEGRADED`; compare counters by connection age. Do not tune MTU, buffers,
BBR, qdisc or firewall before this evidence exists.

The controlled failover harness requires explicit application-level readiness
commands and is scoped to the additive Reality service:

```bash
bash scripts/g1-v2-failover.sh --yes \
  --fallback-ready='...' --primary-ready='...'
```

The command is not run by CI and is not a substitute for independent SSH,
WireGuard-admin and VPS reboot checks.

## 延迟改造的证据门槛

跨境链路上的内核调优、协议切换和路径变更都必须先有基线证据。先采集 T0：

```bash
bash scripts/g1-v2-server-state.sh .temp/server-state-T0.json T0
bash scripts/edge-path-diagnose.sh <EDGE_HOST> 5201 15
```

基线必须覆盖两个时间窗（本地时间 14:00–16:00 与 20:00–23:00），否则晚高峰的
丢包与抖动无法与日常值区分。采集完成后才允许应用数据面调优：

```bash
# 查看现状与证据门槛（不改动主机）
bash scripts/data-plane-sysctl.sh --check .env

# 应用。拒绝执行的条件：.env 中 EDGE_SYSCTL_ACK 不为 1，或没有 24 小时内的 T0 证据
bash scripts/data-plane-sysctl.sh --apply .env

# 回滚到 --apply 前的取值
bash scripts/data-plane-sysctl.sh --rollback .env
```

`deploy/sysctl/edge-2c2g-30m.sysctl` 的取值按 2 vCPU / 2GB / 30Mbps 主机定值：
30Mbps、150ms RTT 的带宽时延积约 576KB，4MB 套接字缓冲区约 7 倍余量。不要在
2GB 主机上继续放大缓冲上限。`EDGE_ENABLE_CAKE=1` 只在实测到 bufferbloat
（空闲 RTT 正常、满载 RTT 飙升）时才启用。

调优后必须在同一时间窗复测，比较 `rtt_p95`、TCP 单流吞吐、UDP 丢包与 SSH 交互
手感；`udp_receive_errors`、`nic_rx_drops`、softnet drop 不得上升，CPU 不得持续
超过 80%。不要用 ICMP RTT 与 HTTPS 总耗时互相比较。

## 客户端选路

`client/mihomo/config.yaml.example` 是传输验证用的 canary：固定顺序、`REJECT`
兜底、不启用 TUN，不要为了"更快"修改它的语义。

日常使用复制 `client/mihomo/config.low-latency.yaml.example`：按实测延迟选路、
国内流量 `DIRECT`、fake-ip DNS、TUN 抓包。两个 profile 不要同时生效，也不要与
全隧道 WireGuard profile 同时启用。

## 观察面板

面板在刷新时保留上一次的内容，不会整屏空白；后台轮询使用更短的超时预算。
`/api/v1/node/snapshot` 是把全部观察资源合并成一次往返的只读端点，旧版服务端
不提供该路由时客户端会自动回退到逐资源请求。
