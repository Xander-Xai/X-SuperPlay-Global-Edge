# Mihomo G1 v2 canary

`config.yaml.example` is a canary profile. It is deliberately not a full
WireGuard replacement and does not enable TUN capture by default. Enable one
client control plane at a time after route isolation is proven; do not run a
full-tunnel WireGuard profile and Mihomo TUN capture together.

Replace every `REPLACE_WITH_EXTERNAL_*` value from the private secret store.
The profile uses application-level fallback checks: `REALITY-SG` is first and
`HY2-SG` is second. If both fail, `REJECT` is selected rather than `DIRECT`, so
global traffic cannot silently bypass the reliability plane.

## P11 isolated canary placeholders

`HY2_CANARY_NODE` and `REALITY_CANARY_NODE` are documentation/template nodes
only. Populate them in a separate, untracked canary provider after a fresh
port-ownership review; never overwrite the user's normal Clash Verge/Mihomo
node set and never enable TUN capture as part of preparation.

The HY2 placeholder contract is:

```text
server: <EDGE_HOST>
port: 443
password: <HY2_PASSWORD_EXTERNAL>
sni: <HY2_SNI>
skip-cert-verify: false
```

Leave bandwidth/Brutal values unset. A process or listener is not functional
evidence; only a real application request through HY2 can establish
`HY2_APPLICATION_PATH_FUNCTIONAL`.
