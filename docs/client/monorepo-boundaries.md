# X-SuperPlay Global Edge Monorepo Boundaries

**Status:** P13-002 isolation contract.

X-SuperPlay Global Edge remains one repository, but its planes have separate
runtime, dependency, deployment, and failure boundaries. A shared Git history
does not authorize a desktop build to modify or package production networking.

## 1. Planes

### Data Plane

The data plane carries or terminates user traffic:

- WireGuard and its client/server configuration;
- Xray Reality;
- future Hysteria2;
- Windows routing, DNS, firewall, proxy, and tunnel state;
- VPS/container runtime and production network configuration.

Data-plane assets live under existing `deploy/`, `runtime/`, `server/`,
`infra/`, `ops/`, and related production paths. P13-002 does not modify them.

### Reliability / Control Plane

The control plane observes and describes the data plane:

- `tools/edge-health-agent/` probe, evidence, and alert logic;
- `services/edge-health-api/` read-only API;
- P12 runtime-state, node identity, and Prometheus adapter;
- local evidence and health contracts.

The control plane is the backend authority for observed state. The desktop
must not duplicate health calculation or create a second runtime state model.

### Experience Plane

The experience plane presents control-plane state:

- `apps/edge-desktop/` Tauri/React/TypeScript/Vite client;
- `docs/client/` client architecture, contracts, audits, and boundaries;
- desktop-only CI/release workflows;
- `scripts/ci/check-edge-desktop-boundary.py`.

P13-002 is read-only. The experience plane has no functional connect,
disconnect, restart, switch, recovery, tunnel, service, or protocol control.

## 2. Dependency boundaries

```text
Experience Plane (apps/edge-desktop)
        | HTTP GET / mock adapter
        v
Reliability / Control Plane (services/edge-health-api)
        | reads
        v
Evidence / health / alert outputs
        |
        v
Data Plane (WireGuard / Xray / Hysteria2)
```

- Desktop dependencies stay under `apps/edge-desktop/`; they do not require
  Python agent/API dependencies, Docker, WireGuard, Xray, or VPS access.
- Backend Python dependencies stay under their existing service/tool paths;
  desktop `npm install` must not install them.
- Desktop CI uses mocks and local fixtures. It never contacts production.
- Server deployment must not depend on desktop Node/Rust dependencies.
- No package-manager migration or repository-wide dependency graph is made.

## 3. Allowed desktop patch surface

P13-002 desktop work may write only:

```text
apps/edge-desktop/**
docs/client/reference/**
docs/client/monorepo-boundaries.md
.github/workflows/edge-desktop-ci.yml
.github/workflows/edge-desktop-release.yml
scripts/ci/check-edge-desktop-boundary.py
```

`docs/client/client-architecture-prd.md` and `README.md` are minimal-
write exceptions only when needed to record the desktop contract. Existing
backend/API and health-agent paths are read-only for this phase.

## 4. Forbidden desktop side effects

Desktop code and workflows must not:

- SSH to, deploy to, or mutate a VPS/server;
- modify WireGuard, Xray Reality, Hysteria2, routing, DNS, firewall, proxy,
  registry, service-manager, or runtime files;
- execute shell, PowerShell, `cmd.exe`, or arbitrary privileged file access
  through Tauri commands;
- store or request production private keys, UUIDs, client profiles, SSH
  credentials, or production API credentials;
- enable updater, notification, auto recovery, node switching, or runtime
  orchestration;
- label a local/mock build as production-ready.

## 5. Boundary check contract

`scripts/ci/check-edge-desktop-boundary.py` is deterministic and read-only.
It accepts explicit changed paths (or reads Git's tracked diff when no paths
are provided), normalizes separators, and fails closed when a forbidden path
or desktop-side native mutation pattern is present. It never edits detected
files. CI calls it after checkout and before desktop validation.

The check recognizes at least:

```text
deploy/**
runtime/**
server/**
infra/**
ops/**
client/wireguard/**
client/mihomo/**
```

The current repository's production-sensitive configuration remains outside
the desktop patch surface even when it is adjacent to client-facing assets.

## 6. Acceptance invariant

```text
SAME REPOSITORY
!= SAME RUNTIME
!= SAME DEPLOYMENT
!= SAME DEPENDENCY GRAPH
!= SAME FAILURE DOMAIN
```

A desktop build passing locally proves only experience-plane build and test
behavior. It does not prove P11 production readiness, data-plane health,
server state, or an end-to-end VPN connection.
