# P13-002 Reference Provenance

## Reference identity

```text
REFERENCE_REPO=https://github.com/clash-verge-rev/clash-verge-rev
REFERENCE_BRANCH=dev
REFERENCE_COMMIT_SHA=9cb4ce6cb1d98cd2764c6fb80f012af2a27e6c84
REFERENCE_LICENSE=GPL-3.0-only
```

The repository `package.json` at this commit declares `GPL-3.0-only`; the
repository `LICENSE` contains GNU GPL version 3. The audit used source tree,
raw-file, and commit pages pinned to the exact SHA. No runtime execution,
networking activation, Mihomo execution, or Clash configuration import was
performed.

## What was studied

- root package scripts, pnpm package-manager declaration, and Vite/Tauri
  build/typecheck/test commands;
- React source organization under `src/`, including layout/navigation,
  providers, services, and page composition;
- Rust/Tauri entrypoint, plugin/lifecycle structure, capabilities, and window
  handling under `src-tauri/`;
- Cargo workspace organization and target-specific Windows configuration;
- NSIS/WebView2 modes, frontend path filtering, CI validation, and release
  artifact workflow;
- generic error/loading/empty-state, logging, tray, settings, updater, and
  diagnostic patterns as documented in the audit matrix.

## Provenance decisions

```text
DIRECT_SOURCE_CODE_COPIED=NO
DIRECT_GPL_SOURCE_CODE_REUSED=NO
REFERENCE_ASSETS_COPIED=NO
REFERENCE_BRANDING_COPIED=NO
```

P13-002 uses clean-room implementations of the documented generic patterns.
Tauri, React, TypeScript, Vite, and other dependencies remain independently
licensed third-party dependencies. No Clash Verge Rev source file, commit,
icon, logo, screenshot, CSS block, React component, Rust module, installer
template, or WebView2 runtime is copied, vendored, cherry-picked, or
mechanically translated.

## Review gate

If a future change appears to require direct GPL code reuse, stop and obtain
explicit approval. The required status is:

```text
GPL_REUSE_REQUIRES_EXPLICIT_APPROVAL
```

Until that approval exists, continue with an independent implementation or
reject the proposed reuse.
