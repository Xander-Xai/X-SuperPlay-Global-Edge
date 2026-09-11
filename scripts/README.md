# 公开自动化脚本

本目录只保留可公开复用的校验、部署和恢复脚本。脚本通过参数或仓库外的环境文件接收真实主机地址，不包含任何生产 IP、账号、客户端身份或事故测量值。

## 脚本矩阵

| 脚本 | 用途 |
|---|---|
| `validate.sh <env>` | 配置契约校验 |
| `preflight.sh <env>` | 主机就绪性检查 |
| `deploy.sh <env>` | 部署并执行控制面检查 |
| `healthcheck.sh <env>` | 服务健康检查 |
| `wireguard-check.sh <env>` | WireGuard 状态检查 |
| `data-plane-tune.sh --check|--apply <env>` | MTU/MSS 策略 |
| `p8-check.sh <env>` | 主机聚合门禁 |
| `client-e2e.ps1` | 参数化真实客户端验收 |
| `edge-qualify.sh <server> ...` | 候选路径双向测试 |
| `edge-race.sh label=host ...` | 候选路径比较 |
| `edge-path-diagnose.sh <ingress> ...` | 参数化路径诊断 |
| `gost-ingress-relay.sh` | 参数化同源中继渲染/检查 |
| `gost-runtime-smoke-test.sh` | 本地中继运行时冒烟测试 |
| `machine-contract-test.sh` | WireGuard 机器输出契约 |
| `backup.sh` / `restore.sh` | 持久状态备份与恢复 |
| `destroy.sh` | 显式停止/删除栈 |
| `secret-scan.sh` | 跟踪内容的凭据形态扫描 |
| `self-test.sh` | 仓库回归检查 |

## 安全边界

- 真实 `.env`、客户端配置、私钥、QR 码和备份文件必须位于仓库外。
- 任何生产主机、云账号、内网地址、runner 身份和原始验收输出都保存在私有运营资料中。
- 脚本缺少必要配置或无法判断状态时必须失败关闭。
- 公开仓库中的命令示例只能使用参数名或文档保留地址。
