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
