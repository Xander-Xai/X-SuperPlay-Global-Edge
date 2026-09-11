# Secret Rotation

Defines when and how secrets rotate, and what to do when a secret is
suspected of exposure. Applies to WireGuard peer keys, the wg-easy admin
credential, and SSH keys.

## Scope of secrets in this project

| Secret | Where it lives | Rotation trigger |
| ------ | -------------- | ---------------- |
| WireGuard peer private key | client device + wg-easy volume | device lost/stolen, config leaked, peer revoked, suspected compromise |
| wg-easy admin password | browser + wg-easy volume state | personnel change, exposure, credential age > 90 days |
| SSH private key (admin) | owner device only | device loss, exposure, key age policy |
| Public host IP inventory | untracked asset log | — (not secret, but keep out of Git per P3) |

## Rotation procedures

### WireGuard client (peer)

Create-new-then-delete keeps service continuity and minimizes lockout risk.

```text
1. In wg-easy admin UI: create a new client following docs/client-naming.md
2. Install the new config on the target device
3. Verify connectivity over the new tunnel
4. Delete the old client in wg-easy (deletion guarantees the old key no
   longer authenticates)
5. Update the local asset log (name, date, reason)
```

The old config file must be destroyed on the old device and any export
medium. There is no "rename to old" state: a deleted client is the only state
that guarantees non-authentication.

### wg-easy admin password

```text
1. Reach the UI over the SSH tunnel (see docs/security.md §2)
2. Change the password in the UI; confirm a fresh session works
3. Optionally reset the browser session by clearing site data
4. Record the rotation date in the ops log
```

### SSH key

```text
1. Generate a new key pair on the owner machine (ed25519)
2. Append the new public key to ~/.ssh/authorized_keys on the host
3. Verify login with the new key in a fresh session
4. Remove the old public key from authorized_keys
5. Destroy the old private key on the owner machine
6. Record the rotation in the ops log
```

## Compromise response

If a WireGuard client key or config is suspected exposed:

```text
1. Revoke immediately (delete the client in wg-easy)
2. Do not reuse the same IP range/name pattern in a way that confuses audit
3. Create a replacement client and reinstall on the trusted device
4. Record: client name, revocation time, reason, replacement name
```

If the host or admin credential is suspected compromised, treat the host as
compromised and follow `docs/recovery.md` (destroy/rebuild from Git + external
secrets) instead of patching in place.

## Rules

- Rotation evidence is recorded locally (ops log): name, timestamp, reason,
  repository SHA when relevant. No keys or passwords in the evidence.
- Keys are never emailed, committed, or stored in chat history.
- Backups containing key material are encrypted at rest by their storage
  mechanism and are never part of the Git repository.
