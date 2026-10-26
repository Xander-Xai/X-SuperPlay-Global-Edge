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

## Two profiles, two jobs

| Profile | Job | Selection | TUN | Direct routing |
|---|---|---|---|---|
| `config.yaml.example` | Transport canary — prove one transport at a time | fixed order (`fallback`) | disabled | none |
| `config.low-latency.yaml.example` | Everyday use | measured delay (`url-test`) | enabled | mainland traffic direct |

The canary keeps its fixed order and `REJECT` fallback on purpose: it is the
isolation surface used to prove that a single transport works. Do not "improve"
it with latency selection, because that hides which transport actually carried
the traffic.

The low-latency profile is the one to copy into the daily client config. It
changes three things relative to the canary:

1. **Measured selection instead of fixed order.** `LATENCY-AUTO` is a
   `url-test` group, so the faster of Hysteria2 and Reality is used instead of
   whichever one happens to be listed first. `GLOBAL-STABLE` remains a
   `fallback` with `empty-fallback: REJECT`, so a full outage fails loudly
   instead of silently bypassing the reliability plane.
2. **Mainland traffic stays local.** `GEOSITE,cn` and `GEOIP,CN` route to
   `DIRECT`. Sending domestic sites through Singapore roughly triples their
   round-trip time and burns the 30 Mbps / 1024 GB budget on traffic that never
   needed to leave the country. `MATCH` still falls back to `GLOBAL-STABLE`.
3. **DNS is managed.** `fake-ip` returns a synthetic address immediately and
   lets the edge resolve the real domain, so a slow cross-border lookup stops
   showing up as a stalled page load. `proxy-server-nameserver` deliberately
   uses domestic resolvers so resolving the proxy server itself never depends
   on the tunnel.

### Operating notes

- TUN capture and a full-tunnel WireGuard profile must not run at the same
  time. Disconnect WireGuard before enabling TUN, and use the split-tunnel
  WireGuard profile (`AllowedIPs = 10.42.42.0/24, <EDGE_PUBLIC_HOST>/32`) when
  both are needed for different destinations.
- Do not enable `udp-over-tcp`. It converts packet loss into TCP head-of-line
  blocking, which is the failure mode this profile exists to avoid.
- `GEOIP,CN` needs a GeoIP database present in the client (Clash Verge ships
  one). Confirm the file exists before trusting the rule.
- The `LATENCY-AUTO` order in the file is display order only. If path
  diagnosis shows the uplink throttles or drops UDP, remove Hysteria2 from the
  group and keep Reality.
