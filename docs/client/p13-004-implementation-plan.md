# P13-004 Secure Observation Channel Implementation Plan

This is a gated plan for later work. P13-004 itself implements none of the
steps below, creates no credentials or certificates, and performs no VPS,
firewall, route, DNS, proxy, Docker, WireGuard, Reality, or Hysteria2 change.

P13-004A1 is documentation-only: no production mutation occurred, no SSH
session occurred, no firewall change occurred, no certificate or credential
was created, no API was publicly exposed, and no runtime control was
implemented.

## Stage map

| Stage | Scope | Exit gate | Explicit non-action |
|---|---|---|---|
| P13-004A | Architecture and threat model | Threat model, channel ADR, and this plan reviewed; target remains a read-only observation channel | No code, credentials, listener, or deployment |
| P13-004B | Local/non-production proof | A disposable local API/TLS fixture proves server identity, client identity, revocation behavior, GET-only authorization, timeout, stale, and unavailable UI semantics | No production host, real certificate, or real secret |
| P13-004C | Production preflight read-only audit | Evidence captures current listeners/ports, independently reconfirms latest-known TCP/443 canonical Xray Reality ownership, checks UDP/443 without fabricating HY2 state, confirms UDP/51820 WireGuard, TCP/51821 admin, SSH, firewall, API bind, and rollback artifacts | No mutation and no tunnel against production |
| P13-004D | Founder-authorized production canary | Exact prechange evidence, approved channel/port, identity proof, unauthorized-client rejection, Desktop real-API success, and rollback rehearsal all pass | No opportunistic TCP/443 sharing; no data-plane replacement |
| P13-004E | Desktop real-API acceptance | Client connects through the approved channel; current, stale, unavailable, malformed, version, cancellation, and last-known-good states are visibly correct | No runtime-control UI or privileged command |
| P13-004F | Rollback/recovery acceptance | Channel can be disabled and credentials revoked; API loopback, SSH, WireGuard, Reality/HY2 ownership, and existing health evidence remain intact | No automatic recovery or failover implementation |

Each stage must produce an immutable evidence record and an explicit pass,
fail, or blocked result. A later stage cannot waive an earlier failed gate.

## P13-004A — architecture/threat-model review

Review the companion threat model and ADR against the repository's current
read-only API and network ownership documents. Confirm:

- no unauthenticated public API is recommended;
- renderer long-lived secret storage is forbidden;
- bootstrap and product channels are distinct;
- TCP/443 and UDP/51820 ownership is preserved;
- WireGuard, Reality, and Hysteria2 circular observability is explicit;
- a second VPS is optional, not invented as mandatory.

Deliverable: approved design record or a blocked record naming the missing
evidence.

## P13-004B — local/non-production proof

Use only disposable local fixtures and test identities. Demonstrate:

1. server certificate/identity validation and hostname/audience binding;
2. client authentication with an observer-only identity;
3. rejection of expired, revoked, wrong-audience, and unknown clients;
4. GET observation success and rejection of POST/other mutations;
5. bounded response size, timeout, and rate behavior;
6. renderer receives observation data but never the long-lived credential;
7. backend unavailable, stale, malformed, and unsupported-version rendering;
8. no secret in Git, logs, artifacts, screenshots, or test evidence.

No local proof may be presented as VPS or production acceptance.

## P13-004C — production preflight read-only audit

Before any proposed mutation, capture exact, timestamped, private evidence.
The historical repository port ADR is not a substitute for this fresh
discovery: its earlier `TCP_443_OWNER = BLOCKED` state records what was unknown
at that time, while the latest known runtime-canary evidence reports canonical
Xray Reality on TCP/443. `PRECHANGE_RECONFIRMATION_REQUIRED = TRUE`.

Capture:

- current processes, listeners, and container port mappings;
- TCP/443 owner and Reality status;
- UDP/443 ownership and Hysteria2 status, if any; do not infer that HY2 is
  deployed or active from a candidate configuration;
- UDP/51820 WireGuard owner and peer/handshake state;
- TCP/51821 loopback admin ownership;
- SSH listener, host-key fingerprint, and access path;
- current API bind, API evidence root, and read-only route behavior;
- firewall/Lighthouse policy and the proposed dedicated observation port;
- encrypted/off-host rollback copies and a tested restore procedure.

If ownership is unknown, stop. Do not select a random port, kill a listener,
or infer that a documented service is deployed from configuration alone.

## P13-004D — founder-authorized production canary

The canary requires a written approval naming the exact host, port, commit,
credential scope, operator, time window, and rollback owner. Acceptance must
prove all of the following:

- exact prechange VPS evidence is archived;
- current TCP/443 Reality ownership is unchanged;
- WireGuard UDP/51820 is preserved and usable;
- SSH remains usable;
- loopback API remains read-only and locally bound behind the channel;
- no secret is committed to Git or emitted in logs;
- endpoint authentication and server identity validation succeed;
- an unauthorized client is rejected;
- the Desktop receives real API data through the approved channel;
- backend unavailable, stale, malformed, and unsupported-version states are
  truthful and visibly distinct;
- rollback is performed or rehearsed according to the approved plan and
  restores the prechange evidence state.

Any failed item blocks product rollout. A successful canary is not permission
to add runtime control or alter the data plane.

## P13-004E — Desktop real-API acceptance

Run on a controlled Windows test host with the approved endpoint only. Verify
server identity before payload acceptance, then exercise the existing client
contract and resilience invariants. Confirm that the renderer cannot read or
export the long-lived credential and that the UI never presents stale healthy
state as current/live.

Acceptance evidence must include client version/build identity, API major
version, source timestamp, received timestamp, freshness state, bounded error
category, and the test endpoint identity. Do not collect private keys, full
credentials, unrestricted evidence, or support bundles.

## P13-004F — rollback/recovery acceptance

Rollback must be a controlled operator action, not automatic recovery. Verify:

1. disable the observation ingress or revoke its client identity;
2. restore the prechange listener/firewall/API configuration snapshot;
3. verify TCP/443 Reality ownership and UDP/51820 WireGuard ownership;
4. verify SSH/admin access and loopback API behavior;
5. verify Desktop reports backend unavailable rather than runtime critical;
6. preserve evidence of the rollback and any residual stale state;
7. close or rotate temporary credentials outside Git.

Only after rollback evidence passes may a later implementation review decide
whether to keep the product channel enabled.

## Required evidence package for future implementation review

- approved architecture/threat-model/ADR versions;
- local proof outputs with disposable identities;
- read-only VPS preflight snapshots;
- port ownership and firewall evidence;
- certificate/server/client identity and revocation test results;
- Desktop real-API acceptance results;
- rollback proof and residual-risk statement;
- explicit confirmation that runtime, server, and production network mutation
  remained within the approved change scope.

No stage in this plan authorizes production execution by itself.
