# Architecture

The public stack is a provider-neutral reference for an edge node. A client
uses a selected transport to reach an edge host and then the host provides
outbound connectivity. Endpoint identity and credentials are external inputs.

```text
Windows / Android
       |
       +-- WireGuard (private/admin or data-plane profile)
       +-- optional Xray VLESS + Reality
       +-- optional Hysteria2
       v
Edge host -> outbound Internet
```

## Repository responsibilities

This repository owns composition, configuration contracts, validation, secret
boundaries, read-only observation, and recovery procedures. It does not own
the upstream WireGuard, Xray, Hysteria2, or wg-easy implementations.

## Reliability model

The additive transport plane is opt-in. A client reliability layer may observe
application-level success, latency, loss, throughput, and connection age,
then recommend a manually approved fallback. Process presence or one TCP
handshake is not application acceptance.

## Observation boundary

The health API is read-only and should remain loopback-only until a separately
reviewed authenticated ingress is available. The desktop observer renders
bounded responses and clearly distinguishes loading, unavailable, malformed,
stale, and healthy states. It has no runtime-control commands.

## Local validation

Compose rendering, shell/Python tests, and the desktop app can be validated
locally with synthetic fixtures. Production deployment, credentials, host
topology, and raw runtime evidence are outside this public architecture.
