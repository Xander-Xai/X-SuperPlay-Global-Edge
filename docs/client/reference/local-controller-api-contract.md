# Local controller API contract

**Status:** Proposed for milestone 0.2. This contract is a companion to
[ADR-0001](adr-0001-local-runtime-architecture.md) and implements no runtime
control by itself.

## Scope

This contract defines the loopback-only control plane between the desktop
renderer and the local controller. The controller owns the managed core
lifecycle. The renderer must not talk to the core or the privileged helper
directly.

The renderer calls one narrow Tauri command, `controller_request`, which runs in
the desktop shell. The shell owns the controller token, forwards the request
over the authenticated local channel, and returns only the bounded response.
The renderer never receives the token and never opens the channel itself.

## Transport

- Preferred: a Windows named pipe with an ACL for the current user.
- Fallback: HTTP bound to `127.0.0.1` on a random port. Never bind `0.0.0.0`.
- JSON request and response bodies.
- Maximum request and response size: 64 KiB.
- Timeouts: 2 seconds for reads, 10 seconds for connect and disconnect.
- Every response carries `contract_version: "1"`.

## Authentication

- The controller generates a random 32-byte token at first launch.
- The token is stored in Windows Credential Manager, not in a file, the
  repository, the renderer, logs, or diagnostics.
- The desktop shell reads the token at startup and authenticates each request.
- Compare tokens in constant time. Reject missing or invalid tokens with the
  same bounded `unauthorized` error and no detail.
- Rate-limit repeated failures and record only a category and timestamp.
- The privileged helper authenticates the controller separately. This contract
  does not authorize helper calls from the renderer.

## Operations

### `status`

Read-only. Always available, including during transitions.

```json
{
  "contract_version": "1",
  "controller_version": "0.2.0",
  "state": "ready",
  "active_transport": "reality",
  "since": "2026-10-27T00:00:00.000Z",
  "last_error_category": null,
  "evidence_ref": "local-2026-10-27T00:00:00Z"
}
```

### `connect`

```json
{ "profile_id": "profile-1", "operation_id": "client-generated-id" }
```

- Serialized by the controller; only one connect or disconnect runs at a time.
- Repeating the same `operation_id` returns the same result.
- `409 already_connected` when the same profile is already ready.
- `409 busy` while another transition is running.
- `404 unknown_profile` when the profile does not exist.

### `disconnect`

- Idempotent. Returns the `stopped` state when already stopped.
- Restores proxy, route, DNS, and TUN state before reporting success.

### `transports`

```json
{
  "transports": [
    { "name": "reality", "protocol": "vless", "state": "ready", "version": "1.0.0" },
    { "name": "hysteria2", "protocol": "hysteria2", "state": "disabled", "version": "2.0.0" }
  ]
}
```

### `diagnostics`

Bounded and redacted. Returns counters, recent state transitions, and error
categories. It must not return tokens, private keys, full profiles, endpoints,
or file paths.

## Error model

```json
{
  "error": {
    "code": "busy",
    "category": "conflict",
    "retryable": true,
    "message": "another transition is running"
  }
}
```

Allowed codes: `unauthorized`, `invalid_request`, `not_found`, `conflict`,
`busy`, `unsupported`, `timeout`, `internal`. Messages are bounded and contain
no secrets, stack traces, paths, or endpoints.

## State machine

```text
disabled -> starting -> ready -> degraded
                            \-> failed -> cooldown -> starting
                            \-> stopped
```

- `starting` has a bounded readiness deadline.
- `degraded` keeps the last-known-good transport while reporting the failure.
- `cooldown` prevents restart storms.
- Every transition records a timestamp, reason category, and evidence reference.

## Concurrency and idempotency

- One transition at a time; reads are never blocked by a transition.
- `operation_id` is client-generated and scoped to the controller lifetime.
- Duplicate operations return the original result rather than starting a second
  transition.
- The renderer polls `status` on a bounded interval; no unbounded event stream
  is required for v1.

## Compatibility

- `contract_version` is a major-version string.
- Additive fields are allowed; clients ignore unknown fields.
- A breaking change requires a new major version and a capability check before
  the client sends the operation.
- The controller must reject unknown operations and unknown required fields.

## Security requirements

- Loopback or named pipe only; no remote listener.
- Fixed operation allowlist; no shell, no arbitrary path, no generic command.
- Strict schema validation and bounded request size, timeout, and concurrency.
- The Tauri capability list exposes only `controller_request`; the renderer
  keeps no native process or filesystem permissions.
- Audit records contain operation name, timestamp, and result category only.

## Non-goals

- No remote control, multi-user access, node switching, or automatic recovery in
  v1.
- No privileged operations in this API. The helper has its own separate
  contract.
- No profile contents, endpoints, keys, or tokens in responses.

## Acceptance criteria

- Contract tests cover idempotent connect, busy conflict, unknown profile,
  unauthorized rejection, timeout, and bounded diagnostics.
- Tests use a local mock controller and fixtures only.
- The renderer never receives the controller token.
- `status` remains available during every transition.
