# Recovery

## Principle

The server is replaceable. The system is recoverable from:

```text
Git repository
+ external secrets
+ documented asset metadata
+ required runtime backup material
```

## Failure classes

Recovery planning must cover:

1. container/service crash;
2. host reboot;
3. bad configuration change;
4. failed upstream upgrade;
5. lost server / rebuild onto a fresh host;
6. compromised or revoked client credential.

## Implemented (P3/P5)

Backup/restore/destroy are now executable primitives:

- backup scope: the `etc_wireguard` volume (all wg-easy/WireGuard state,
  including keys) → `scripts/backup.sh`; a running service is briefly stopped
  for a consistent snapshot (stop → archive → start → wait-healthy), a
  stopped service stays stopped;
- restore sequence (transactional): confirm → detect whether the service was
  running → stop the service → take a **stopped-state safety backup** (abort
  if empty, leaving the original state untouched) → clear volume → extract →
  restart **only if** it was running → healthcheck → `scripts/restore.sh`;
- destroy/rebuild sequence: `scripts/destroy.sh [--yes] [--volumes]` then
  redeploy from Git + `.env`;
- secret rotation & revocation: `docs/secret-rotation.md` + `docs/client-naming.md`;
- the CI `stack-lifecycle` job continuously verifies
  deploy → backup → destroy → restore → health on a real engine.

## P8 requirements (first remote host)

Before G1 completion on the real host:

- test reboot recovery;
- test at least one configuration rollback;
- verify client revocation and replacement path end-to-end.

## Secret handling

Backups containing keys or credentials must never be committed to Git. Their storage/encryption mechanism is selected in P3/P5 based on actual workload.

## Recovery evidence

A recovery test should record date, triggering scenario, repository SHA, result, manual interventions, and whether the documented procedure was sufficient.

## G1 v2 rollback boundary

The new server plane is additive and opt-in. To return to the accepted
WireGuard baseline, stop the `deploy/g1-v2/docker-compose.yml` project, restore
the pre-change firewall/config snapshot, and run the existing `healthcheck.sh`,
`wireguard-check.sh` and `p8-check.sh` gates. Do not delete the wg-easy volume,
legacy full-tunnel client profile, GOST relay or wstunnel recovery assets.

`scripts/g1-v2-failover.sh` only stops and starts the new Reality service and
requires explicit application probes; it never deletes configuration.
