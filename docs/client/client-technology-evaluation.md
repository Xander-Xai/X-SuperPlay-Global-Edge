# X-SuperPlay Edge Client Technology Evaluation

**Status:** Architecture evaluation only; no framework has been installed or
implemented by P13-001.

## 1. Evaluation context

The product is an API-first control plane with three likely consumers:
desktop, Android, and web. The first client must be useful for read-only
health and runtime observation while leaving protocol processing in the Edge
Runtime. The technology therefore needs a small trusted shell, reliable HTTPS
and JSON/text handling, protected credential storage if authentication is
added later, and a path to platform-specific distribution.

Scores below are design estimates on a 1–5 scale (5 is strongest). They are
trade-off signals, not benchmark measurements or a deployment decision.

## 2. Comparison

| Criterion | Tauri 2 | Electron | Flutter |
|---|---:|---:|---:|
| Desktop bundle/resource footprint | 5 | 2 | 3 |
| Small trusted surface / permission minimization | 5 | 2 | 3 |
| Desktop web UI reuse | 4 | 5 | 3 |
| Native desktop integration | 4 | 5 | 4 |
| Android path | 2 | 1 | 5 |
| Mature JavaScript ecosystem | 4 | 5 | 2 |
| Consistent custom rendering across platforms | 3 | 3 | 5 |
| Fit for API-first read-only MVP | 5 | 4 | 4 |

### Tauri 2

**Strengths**

- Lightweight desktop shell using the system webview, with a small native
  command surface that can be kept read-only.
- Rust boundary makes explicit permission and capability review practical.
- Good fit for an existing web-oriented control-plane UI and a separate API
  adapter.

**Trade-offs**

- System webview versions can vary across operating systems and need a
  compatibility matrix.
- Rust introduces a second language/toolchain for native commands and secure
  storage.
- Android support exists in the ecosystem but is not as unified or mature for
  this product shape as Flutter's mobile path.

**Security implication:** Tauri is attractive when the desktop client remains
thin and the native bridge exposes only explicit, audited commands. It does
not make an unsafe bridge safe automatically.

### Electron

**Strengths**

- Strongest reuse of the JavaScript/TypeScript desktop ecosystem and mature
  debugging, packaging, and web compatibility.
- Consistent bundled Chromium behavior reduces system-webview variance.
- Straightforward integration for a desktop-first dashboard.

**Trade-offs**

- Larger memory and download footprint and a larger bundled attack surface.
- Node.js integration must be carefully isolated from renderer content;
  preload and context-isolation mistakes can expose local authority.
- No practical Android client path from the same shell; mobile requires a
  separate technology.

**Security implication:** Electron is viable only with context isolation,
sandboxing, a narrow preload API, disabled arbitrary navigation, and no
direct renderer access to filesystem or process APIs.

### Flutter

**Strengths**

- First-class Android path and a single rendering model across mobile,
  desktop, and web targets.
- Strong control over responsive client UX and offline/stale-state views.
- A useful option if a unified desktop-plus-mobile product is the primary
  goal from the beginning.

**Trade-offs**

- Larger custom UI/runtime footprint than a thin webview shell for a simple
  dashboard.
- Dart/Flutter networking, desktop packaging, and platform credential
  integration become a separate ecosystem from existing web assets.
- Web output is not automatically equivalent to a browser-native dashboard;
  accessibility and integration require dedicated validation.

**Security implication:** Flutter still requires platform-secure storage and a
carefully constrained platform-channel surface; a single UI toolkit does not
remove native permission review.

## 3. Recommendation

For a desktop-first read-only MVP, evaluate **Tauri 2 first**. It aligns with
the control-plane boundary, can keep the privileged native surface small, and
supports a web-oriented API client without embedding a full browser runtime.

Keep the API contract independent of that choice. If Android becomes a first-
class deliverable at the same time as desktop, run a short implementation
spike comparing Tauri's mobile path with Flutter before committing; Flutter
may then be the better unified client shell. Electron remains a reasonable
fallback when the team values the JavaScript ecosystem and Chromium
consistency more than footprint and native surface minimization.

This recommendation is not authorization to build or deploy any client. It
does not change the Edge Runtime, protocol, server, or P12 API behavior.

## 4. Decision gates for a future implementation

Before selecting a framework, require evidence for:

1. API contract validation against empty, stale, corrupted, and healthy
   evidence states.
2. Protected credential-storage proof using platform facilities, with no
   secret in renderer logs or crash reports.
3. Permission audit showing no raw packet, runtime-config, service-manager,
   or administrator access is needed for read-only observation.
4. Offline/stale-state behavior that preserves source timestamps and never
   authorizes a runtime action.
5. Reproducible packaging, update, and uninstall behavior for the target
   platforms.
6. Accessibility and localization review for desktop, Android, and web views.

## 5. Explicit exclusions

No framework installation, application code, UI, authentication integration,
notification integration, runtime mutation, node orchestration, deployment,
WireGuard change, or Xray change is part of this evaluation.
