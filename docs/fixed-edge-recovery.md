# 公开固定边缘恢复说明

本文件保留固定源站与客户端接入端点分离的通用模型，但不暴露真实区域、IP 或事故数据。真实运行记录在私有运营仓库。

```text
origin = <EDGE_PUBLIC_HOST>
client endpoint = <DIRECT_OR_APPROVED_RELAY>
WireGuard port = <WIREGUARD_PORT>
```

只有在双向 TCP/UDP、MTU/PMTU、完整负载和真实客户端端点身份都通过后，才可将路径标记为可用。中继只能改变接入路径，不得静默改变源站身份。
