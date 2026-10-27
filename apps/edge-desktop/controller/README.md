# Local controller skeleton

**Status:** milestone 0.2 contract skeleton. It implements the contract types,
token authentication, the transport state machine, idempotency, diagnostics,
and a fake in-process core.

It deliberately does **not**:

- start a transport core or a supervisor;
- open a named pipe or TCP listener;
- spawn a process;
- touch proxy, route, DNS, or TUN state;
- read endpoints, credentials, or profiles from disk.

The real sidecar, IPC transport, core supervision, and privileged helper land in
later reviewed changes. See
[ADR-0001](../../../docs/client/reference/adr-0001-local-runtime-architecture.md)
and the
[controller API contract](../../../docs/client/reference/local-controller-api-contract.md).

## Contract harness

The binary reads one JSON request from standard input and prints one JSON
response. It is a local contract harness, not the production IPC listener.

```bash
CONTROLLER_CREDENTIAL="${CONTROLLER_CREDENTIAL:?set a 64-character hex credential}" \
CONTROLLER_PROFILES=reality,hysteria2 \
  cargo run --quiet <<< '{"operation":"status"}'
```

The credential is never printed, logged, or included in diagnostics.

## Checks

```bash
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
```
