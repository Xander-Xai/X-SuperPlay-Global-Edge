# X-SuperPlay Edge Desktop

Read-only Tauri 2 + React + TypeScript + Vite MVP for the X-SuperPlay Global
Edge observation API. It presents Dashboard, Events, and Node views over the
existing read-only state/reliability API. It does not implement a VPN core, WireGuard, Xray
Reality, Hysteria2, service management, runtime mutation, or recovery.

## Local development

The app is dependency-isolated. Run these commands from this directory; no
Python dependencies, Docker, WireGuard runtime, Xray runtime, VPS access, or
production credentials are required:

```powershell
pnpm install
pnpm typecheck
pnpm test
pnpm build
```

For the browser development shell:

```powershell
pnpm dev
```

For a native Tauri development window, install the Tauri 2 platform
prerequisites first, then run:

```powershell
pnpm tauri:dev
```

The current MVP has no native Tauri commands. The Rust layer only creates the
window and the capability file grants no native permissions.

## API modes

Mock mode is the default and never contacts a server. Select a deterministic
fixture with `VITE_EDGE_MOCK_SCENARIO`:

```powershell
$env:VITE_EDGE_MOCK_SCENARIO = "warning"
pnpm dev
```

Supported scenarios are `healthy`, `warning`, `critical`, `unknown`,
`unavailable`, `events`, `stale`, `timeout`, `transient-retry-success`,
`malformed-content-type`, and `unsupported-api-version`.

Real API mode is opt-in:

```powershell
$env:VITE_EDGE_API_BASE_URL = "http://127.0.0.1:8080"
pnpm dev
```

The adapter reads the existing `/api/v1/node/*`, `/api/v1/health/*`,
`/api/v1/events`, and `/metrics` contracts with bounded GET timeout/retry,
content-type and schema checks, source-timestamp freshness, and an in-memory
last-known-good snapshot. No production host, UUID, private key, WireGuard
secret, or SSH credential is embedded in the app or fixtures.

## Tests

`pnpm test` covers:

- healthy, warning, critical/degraded, unknown, and unavailable states;
- API adapter fixtures, malformed JSON, and malformed Prometheus text;
- dashboard metrics/service rendering;
- event, resolved-empty, and error-safe views;
- node identity, versions, provider/region, and capabilities.

Tests use local deterministic fixtures and do not access the public network.

## Native build

```powershell
pnpm tauri:build
```

This builds an app-local Windows NSIS artifact. It requires Rust, the Tauri
2 Windows prerequisites, and WebView2 bootstrapper support on the build host.
The P13-002 workflow uses `workflow_dispatch`, builds on `windows-latest`, and
uploads an artifact named `X-SuperPlay-Edge-Desktop-Windows`. It does not
publish a GitHub Release, sign a production installer, or enable auto-update.

Build identity is injected through `VITE_BUILD_VERSION`, `VITE_BUILD_SHA`, and
`VITE_BUILD_TARGET`; the UI displays the identity in its diagnostic footer.
An artifact metadata file records the same values. A local or workflow build
must not be labelled production-ready.

## Boundary check

```powershell
pnpm boundary
```

The read-only check fails closed for production/runtime prefixes and
secret-shaped paths. It never edits detected files. See
`docs/client/monorepo-boundaries.md` for the full plane contract.

## Deferred and rejected scope

Tray, updater, large settings storage, logs export, profiles, subscriptions,
TUN/system proxy control, native service management, connect/disconnect
buttons, automatic recovery, node switching, and protocol control are not
part of this MVP. Clash Verge Rev informs generic shell and packaging
patterns only; no GPL source or reference asset is copied.
