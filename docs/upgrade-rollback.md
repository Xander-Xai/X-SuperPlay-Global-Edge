# Upgrade & Rollback

Changes to the runtime image or the Compose stack are repository changes, not
runtime edits. This document defines the procedure for both directions.

## Principles

1. The reviewed image tag is a contract (`WGEASY_IMAGE`), enforced by
   `scripts/validate.sh` and CI. Any change to it is a reviewed branch + PR.
2. Before upgrading, a backup must exist (`scripts/backup.sh`).
3. Rollback means returning to the previous pinned image tag from Git history,
   not "fixing it live".
4. Upgrade and rollback are exercised on a disposable environment before the
   real host when feasible (P6 lifecycle test in CI).

## Upgrade procedure

```text
1. Record current running SHA + image tag  (scripts/status.sh)
2. Take a backup                            (scripts/backup.sh)
3. Review the upstream release notes for the target version
4. Branch: update WGEASY_IMAGE (+ .env.example), run scripts/validate.sh
5. Open PR; CI must pass (compose render, healthcheck/lifecycle job)
6. Merge; pull on host                       (git pull)
7. Re-run preflight                          (scripts/preflight.sh)
8. Redeploy                                  (scripts/deploy.sh)
9. Health + smoke check                      (scripts/healthcheck.sh, status.sh)
10. Record result in the ops log (SHA, image tag, outcome)
```

Acceptance criteria after upgrade:

- container reports healthy;
- WireGuard interface state is unchanged/restored;
- existing clients still authenticate (spot-check one client);
- admin UI reachable over the SSH tunnel.

## Rollback procedure

Trigger examples: unhealthy after upgrade, clients failing, UI regression.

```text
1. Stop the service                        (docker compose stop wg-easy)
2. Checkout the previous reviewed revision (git checkout <prev-SHA>)
   or revert the image-tag change locally
3. Re-run validate                         (bash scripts/validate.sh .env)
4. Start the previous image                (scripts/deploy.sh)
5. Health + smoke check                    (scripts/healthcheck.sh, status.sh)
6. Record the rollback in the ops log
7. Fix forward: open a new branch with the corrected change; do not
   treat the rollback as the fix
```

Rollback must never require restoring the volume: `etc_wireguard` data format
is version-independent state; a rollback that needs `scripts/restore.sh`
indicates the upgrade mutated stored state — stop and investigate instead of
blindly restoring.

## Rules

- Never edit a running container's image tag directly on the host.
- Never upgrade with `:latest` or an unpinned digest.
- Never upgrade without a backup and a recorded pre-upgrade SHA.
- If rollback was needed, record the upstream version and reason; retry only
  after understanding the failure.

## G1 v2 transport artifacts

Xray and Hysteria2 are pinned by release tag and image digest in
`deploy/g1-v2/docker-compose.yml`. Upgrade them only through a reviewed branch
after checking the official release notes and recording the old image strings.
Back up the current wg-easy state and the external G1 v2 runtime directory
first. A failed canary is rolled back by stopping the additive project and
restoring the previous external configs; the existing WireGuard stack is not
reinstalled or overwritten.
