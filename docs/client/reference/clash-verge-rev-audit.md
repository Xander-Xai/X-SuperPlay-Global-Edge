# Clash Verge Rev Reference Audit

**Audit type:** Source-level reference audit only. The reference application
was not executed, its networking functionality was not installed or
activated, no Mihomo configuration was imported, and no runtime behavior was
used as production evidence.

**REFERENCE_REPO:** `https://github.com/clash-verge-rev/clash-verge-rev`

**REFERENCE_BRANCH:** `dev`

**REFERENCE_COMMIT_SHA:** `9cb4ce6cb1d98cd2764c6fb80f012af2a27e6c84`

**REFERENCE_LICENSE:** `GPL-3.0-only` (also stated by the reference
`package.json`; the repository `LICENSE` is GNU GPL version 3).

**Audit date:** 2026-09-08

**Reproducibility:** inspect the repository tree and raw files at
`https://github.com/clash-verge-rev/clash-verge-rev/tree/9cb4ce6cb1d98cd2764c6fb80f012af2a27e6c84`.
The commit page is
`https://github.com/clash-verge-rev/clash-verge-rev/commit/9cb4ce6cb1d98cd2764c6fb80f012af2a27e6c84`.

## 1. Findings

The reference is a mature Tauri 2 desktop application with a React frontend,
Rust workspace, explicit Tauri capabilities, route-oriented pages, shared
providers/services, and Windows packaging/release automation. Its actual
product couples the UI to Mihomo and Clash concepts. That coupling is useful
to study for shell engineering but is not a fit for X-SuperPlay's
Edge Control API.

The root `package.json` uses pnpm scripts for web typecheck, Vitest, Vite,
and Tauri builds. `Cargo.toml` declares a Rust workspace containing
`src-tauri` and supporting crates. `src/` is organized into assets,
components, hooks, locales, pages, providers, services, types, and utils.
`src/main.tsx` composes providers, routing, error handling, and preload
behavior. `src/pages/_layout.tsx` supplies the navigation shell and outlet.
`src-tauri/src/lib.rs` owns plugin setup, lifecycle, window handling, and a
large command registry. Capabilities include HTTP, updater, dialog, deep link,
autostart, notification, and Mihomo permissions. That breadth is deliberately
not copied into the X-SuperPlay MVP.

The reference Windows configuration supports NSIS and both an embedded
WebView2 bootstrapper and an optional fixed-runtime configuration. Its
frontend workflow filters paths before installing pnpm and running format,
lint, typecheck, tests, and Knip. Its release workflow is much broader than
P13-002; X-SuperPlay uses only the generic validation and artifact ideas.

## 2. Reference decision matrix

| AREA | CLASH_VERGE_REV_PATTERN | DECISION | RATIONALE | X_SUPERPLAY_IMPLEMENTATION | LICENSE_IMPACT |
|---|---|---|---|---|---|
| Root package/tooling | pnpm scripts, Vite, TypeScript, Vitest, Tauri CLI | ADAPT | Mature isolated desktop tooling is useful; root migration is out of scope. | Keep package files under `apps/edge-desktop/`; use an app-local lockfile and scripts. | Generic tool usage; no GPL source copied. |
| Frontend source architecture | `src/` split into pages, components, hooks, providers, services, types, utils | ADAPT | The separation scales better than page-local fetch calls. | Use `src/api`, `src/views`, `src/components`, and one app shell for the three MVP views. | Independent implementation. |
| X-SuperPlay health/evidence/alerts | Reference-specific core state is surfaced through UI services | BUILD | Health score, evidence provenance, failure classification, and alerts already belong to the P12 platform. | Consume the existing Edge Control API; never recalculate or replace P12 state in the client. | X-SuperPlay-owned contract; no GPL dependency. |
| X-SuperPlay runtime and node identity | Reference-specific core capabilities and service lifecycle | BUILD | WireGuard, Reality, Hysteria2 state, node identity, and declared capabilities are X-SuperPlay domain contracts. | Render `/api/v1/node/*` responses as read-only observations. | X-SuperPlay-owned contract; no GPL dependency. |
| Tauri architecture | `src-tauri/src` Rust library plus a small `main.rs` entrypoint | ADAPT | A Rust boundary is appropriate, but X-SuperPlay has no native runtime commands yet. | Minimal Tauri builder with no custom commands or sidecars. | No reference Rust module copied. |
| Cargo workspace | Root workspace with `src-tauri` and many domain crates | REJECT | A second workspace would increase coupling and violates app isolation. | One app-local `src-tauri/Cargo.toml`; no repository Cargo workspace. | No GPL workspace code reused. |
| Capabilities/permissions | Named capability files with HTTP, updater, Mihomo, system, and window permissions | ADAPT | Explicit capabilities are valuable; reference permissions are too broad/domain-specific. | Empty native permission set for the read-only shell; browser fetch remains in the UI adapter. | No capability file copied. |
| Application lifecycle | Singleton checks, plugin setup, startup phases, run-event handling | ADAPT | Lifecycle/error boundaries matter, but service lifecycle is not an MVP concern. | Tauri default lifecycle only; no singleton, service, restart, or shutdown control. | Independent implementation. |
| Window organization | Main window plus platform-specific window/decorations behavior | ADAPT | A predictable desktop window is useful. | One `main` window with bounded size, no extra webviews or windows. | No window code copied. |
| Navigation | Route-driven layout with a persistent side navigation and outlet | REUSE | Generic information hierarchy matches Dashboard/Events/Node. | Local React view switch with the same conceptual shell, not pixel copying. | Generic pattern only. |
| State management | Provider composition and SWR/preload caches | ADAPT | Loading/error/cache separation is useful; the MVP does not need the full stack. | React state plus an explicit `EdgeApiClient`; no hidden global mutation. | No provider code copied. |
| API/service abstraction | Mihomo plugin/WebSocket/controller abstractions | REJECT | They assume Clash/Mihomo core semantics and privileged control. | `EdgeApiClient` with `HttpEdgeApiClient` and `MockEdgeApiClient` over P12 endpoints. | Avoids derivative Mihomo code. |
| Error/loading/empty UX | Error boundary, preload loading state, notices, fallback handling | REUSE | Explicit state presentation is directly relevant to reliability. | Loading, unavailable, malformed, empty, unknown, and stale-safe views. | Generic UX concept only. |
| Settings organization | Persisted Verge settings, menu order, language/theme settings | ADAPT | A large settings subsystem is not required for read-only observation. | Only `VITE_EDGE_API_BASE_URL` and mock scenario environment inputs; persist nothing in the MVP. | No settings code copied. |
| Logging UX | Structured logging, notices, diagnostic/export paths | ADAPT | Diagnostics help explain API failures, but secrets must stay isolated. | Frontend error presentation only; no privileged log export. | No logging module copied. |
| Tray architecture | Background/tray and lightweight-mode behavior | ADAPT | Tray lifecycle can hide a data-plane action boundary and is not needed for MVP. | Document for later; no tray, background service, or auto-start now. | No tray assets/code copied. |
| Windows packaging | Tauri bundle with target-specific Windows configuration | REUSE | Standard Tauri packaging is an appropriate independent artifact path. | App-local NSIS target and artifact workflow. | Generic Tauri configuration, not GPL code. |
| NSIS configuration | Current-user/per-machine install modes, language selector, installer template | ADAPT | NSIS is useful; reference branding/templates must not be copied. | Minimal current-user NSIS configuration with X-SuperPlay product identity. | No installer artwork/template copied. |
| WebView2 handling | Embedded bootstrapper and optional fixed-runtime artifacts | ADAPT | A bootstrapper is the minimum reasonable Windows strategy. | Embedded bootstrapper only; fixed runtime is deferred. | No reference runtime files copied. |
| GitHub Actions CI | Separate frontend/Rust/release workflows and read permissions | ADAPT | Job separation and read-only permissions fit independent validation. | Path-filtered desktop CI with no secrets/deployment; release is manual artifact-only. | No workflow source copied wholesale. |
| Release artifacts | Multi-platform release, update metadata, signing and publishing | ADAPT | Artifact identity matters; publishing/updater is out of scope. | `workflow_dispatch` Windows artifact named `X-SuperPlay-Edge-Desktop-Windows`. | No release assets or signing material copied. |
| Path-based CI optimization | `dorny/paths-filter` before expensive frontend checks | ADAPT | Prevents unrelated repository work from requiring desktop dependencies. | Desktop workflows run on app/desktop workflow/script/doc changes only. | Generic CI pattern. |
| Dependency isolation | Root package plus workspace packages and sidecar/core dependencies | ADAPT | Isolation is central to this monorepo's safety boundary. | Desktop Node/Rust dependencies stay under `apps/edge-desktop`; backend Python remains separate. | No dependency vendoring from reference. |
| Version/build identity | Package/Tauri version and release tag checks | REUSE | Reproducible artifacts need application version and commit identity. | Build metadata uses version, `VITE_BUILD_SHA`, and target; artifacts are not called production-ready. | Generic metadata pattern. |
| Updater | Tauri updater plugin, signed endpoints, update channels | REJECT | Automatic updates require signing, trust, and release governance outside this MVP. | Document for later; no updater plugin, endpoint, key, or auto-update behavior. | No updater code/key copied. |
| Profiles/subscriptions/rules/TUN | Clash YAML, proxy providers, rule providers, modes, TUN and system proxy | REJECT | These are Mihomo product concepts, not X-SuperPlay contracts. | No profile import, subscription, rule, TUN, system proxy, or mode controls. | Explicitly avoids derivative behavior. |

## 3. Reference-driven implementation decisions

### Application shell

**ADAPT.** Use a persistent shell with a compact navigation rail and a main
content area. Use the information hierarchy, not the reference branding,
icons, CSS, or layout source.

### Tauri boundary

**BUILD minimal.** React owns rendering, API calls, parsing, fixtures, and
error states. Rust/Tauri owns only the native window bootstrap in P13-002.
There are no shell, PowerShell, filesystem, service, route, DNS, firewall,
proxy, WireGuard, or Xray commands.

### Window/lifecycle

**ADAPT only the bounded main window.** Singleton handling, background mode,
service installation, restart paths, and complex platform lifecycle are
deferred.

### Tray

**DOCUMENT_FOR_LATER.** The reference demonstrates the concept; the MVP has
no tray or hidden background control surface.

### Settings

**DOCUMENT_FOR_LATER.** Only environment-based API base URL and mock scenario
are supported. No settings store is introduced.

### Logging

**ADAPT presentation only.** The MVP shows loading, unavailable, malformed,
and retry states. It does not expose privileged diagnostic export.

### Updater

**DOCUMENT_FOR_LATER.** No update plugin or update endpoint is enabled.

### Windows packaging

**REUSE generic Tauri/NSIS knowledge.** Use a current-user NSIS artifact with
X-SuperPlay identity and no copied installer artwork.

### WebView2

**ADAPT minimum strategy.** Use Tauri's embedded bootstrapper mode. A fixed
runtime bundle is deferred until compatibility evidence justifies its size
and maintenance cost.

### CI/release

**ADAPT.** Keep desktop workflows path-aware, read-only, dependency-isolated,
and artifact-only. Do not copy the reference workflow's production release,
signing, updater, or notification behavior.

## 4. DEFERRED_REFERENCE_PATTERNS

The following reference patterns are recorded for later design work and are
not implemented in P13-002:

- system tray and background/lightweight mode;
- automatic updater, signed update metadata, and update channels;
- persisted settings, theme/language system, and menu customization;
- structured native log viewer and diagnostic export;
- Clash profiles, subscriptions, providers, and backup/sync;
- native service management and privileged runtime commands;
- complex window lifecycle, singleton enforcement, and multi-window webviews;
- multi-platform packaging beyond the Windows artifact;
- fixed WebView2 runtime distribution;
- backup, restore, and cloud sync.

## 5. Explicit rejects

The following are not inherited merely because the reference contains them:

- Mihomo controller coupling or Mihomo WebSocket APIs;
- Clash YAML configuration and mode selection;
- proxy providers, subscriptions, rule providers, or profile merge/script;
- TUN, system proxy, service mode, networking privilege escalation;
- copied logos, icons, screenshots, CSS blocks, React components, Rust
  modules, or installer artwork.

## 6. Audit conclusion

`REFERENCE_AUDIT_RESULT=PASS` for source-level architecture guidance.
`DIRECT_GPL_SOURCE_COPIED=NO`.
The reference informs generic shell, packaging, capability, and CI decisions;
X-SuperPlay remains an API-first read-only control plane over its own P12
contracts. This audit does not claim P11 completion or production readiness.
