# G1 v2 additive server plane

This is an opt-in Docker Compose project for the two new transports. It does
not modify or replace the current `deploy/docker-compose.yml` wg-easy stack.

Before activation, complete `docs/g1-v2-port-ownership-adr.md` against the
intended host, create runtime directories outside Git, and render the example
configs with external secrets stored in an approved private boundary. The
example files are schemas only; placeholders must not be used on a live host.

```text
runtime/g1-v2/xray/config.json       # rendered Xray server config
runtime/g1-v2/hysteria/config.yaml   # rendered Hysteria2 server config
```

Validation is intentionally separate from deployment:

```bash
bash scripts/g1-v2-deploy.sh --check
docker compose -f deploy/g1-v2/docker-compose.yml config
docker compose -f deploy/g1-v2/docker-compose.yml config
```

`docker compose up` proves only process/config lifecycle. Real client
application probes, same-VPS protocol comparison, failover and soak evidence
are required before any acceptance claim.
