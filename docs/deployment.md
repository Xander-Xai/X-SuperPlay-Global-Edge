# 公开部署说明

本文件只描述通用部署流程，不记录任何真实服务器地址、云账号、内网地址、客户端名称或生产验收数据。真实资产资料已迁移到受控的私有运营仓库。

## 配置边界

生产配置必须放在仓库外的 `.env` 文件中。公开模板只保留变量名和安全默认值：

```text
EDGE_ENV=development
EDGE_PUBLIC_HOST=
EDGE_WIREGUARD_ENDPOINT_HOST=
EDGE_WIREGUARD_PORT=51820
WG_ADMIN_BIND=127.0.0.1
WG_ADMIN_PORT=51821
```

`EDGE_PUBLIC_HOST`、客户端端点和管理隧道地址不得写入公开仓库。客户端配置、私钥、QR 码和备份文件也不得提交。

## 部署流程

1. 复制 `.env.example` 到仓库外的配置路径并填写真实值。
2. 执行 `bash scripts/validate.sh <env-file>`。
3. 执行 `bash scripts/preflight.sh <env-file>`。
4. 执行 `bash scripts/deploy.sh <env-file>`。
5. 通过 `scripts/healthcheck.sh`、`scripts/wireguard-check.sh` 和真实客户端验收确认状态。

部署成功只代表控制面可运行；真实客户端的双向链路、完整负载、DNS 和端点身份仍需单独验收。

## G1 v2 additive plane (not yet activated)

The new transport definitions are intentionally separate from the current
wg-easy project:

```bash
bash scripts/g1-v2-validate.sh
docker compose -f deploy/g1-v2/docker-compose.yml config
```

Do not run `up` until the live port-ownership ADR is PASS, backups exist, and
external Xray/Hysteria credentials and certificates have been rendered under
the private runtime directory. A process health check or listening port is not
an application acceptance result. Use the protocol-ABC, failover and soak
tools after a real Mihomo canary is connected.
