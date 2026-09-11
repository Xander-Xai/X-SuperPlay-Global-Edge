# Secure observation channel reference

This is a provider- and host-neutral design for exposing a read-only health
API without exposing the data plane or management plane. It is a reference,
not a deployment record or authorization to change infrastructure.

```text
Desktop observer
      |
      | authenticated TLS/mTLS on an approved dedicated ingress
      v
Observation gateway
      |
      | loopback-only HTTP
      v
Read-only health API
```

## Security requirements

- Keep the API GET-only, bounded to an explicit resource allowlist, and reject
  arbitrary paths, methods, upstream targets, and body sizes.
- Keep gateway TLS and authorization separate from data-plane and administrator
  identities. Long-lived credentials never enter the renderer or Git.
- Store certificates, keys, revocation data, and evidence outside the source
  tree with least-privilege read-only mounts.
- Verify both host-level and cloud-provider firewall rules before exposing an
  ingress. Select a separate validated port when an existing transport owns a
  candidate port; never infer availability from documentation.
- Use synthetic fixtures for local validation and retain raw operational
  evidence in a private store.

## Rollback principles

Disable the approved ingress, stop the gateway, revoke the canary identity,
and verify that the API is loopback-only or stopped. Re-check the existing
data-plane and administration contracts after rollback. No automatic recovery,
DNS change, firewall expansion, or data-plane replacement is part of this
reference.
