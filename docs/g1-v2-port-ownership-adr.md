# ADR: additive transport port ownership

Status: reference design. This document contains no live listener or provider
state.

The default deployment manager is Docker Compose. Optional Reality and
Hysteria2 services remain separate from the baseline WireGuard stack and are
never activated solely because a port appears unused in documentation.

Before any future listener change, collect fresh read-only ownership evidence
from the target host and review host/cloud firewall rules. Preserve existing
services, choose a separately validated port for a new ingress, and stop when
ownership is unknown. Do not evict, move, or replace an existing listener.

Every change requires an external secret boundary, a rollback snapshot, a
bounded application test, and post-change checks for the unaffected planes.
`docs/reference/secure-observation-channel.md` describes the same principle
for a read-only observation gateway.
