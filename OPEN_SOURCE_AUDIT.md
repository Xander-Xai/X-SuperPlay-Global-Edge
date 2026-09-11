# Open-source audit

This report records paths, risk classes, severity, and remediation only. It
does not reproduce secrets, endpoints, account identifiers, or raw evidence.

| Path | Risk type | Level | Action |
| --- | --- | --- | --- |
| `OPC-LINK.yaml` | Internal OPC/business metadata | P2 | Deleted from snapshot. |
| `docs/client/p13-004c-production-preflight.md` | Raw production listener/firewall evidence | P1 | Deleted from snapshot. |
| `docs/client/p13-004d-production-change-plan.md` | Mixed production plan and topology | P1 | Deleted; replaced by generic observation-channel reference. |
| `docs/client/p13-004d-ingress-decision.md` | Live ingress/topology decision | P1 | Deleted from snapshot. |
| `docs/p11-r3-phase0-baseline-20260911.md` | Runtime baseline and measurement evidence | P1 | Deleted from snapshot. |
| `docs/g1-v2-evidence-index.md` | Evidence inventory and runtime claims | P1 | Deleted from snapshot. |
| `docs/g1-v2-gate-status.md` | Current production gate status | P1 | Deleted from snapshot. |
| `docs/g1-v2-codex-execution-prompt.md` | Incident and production execution context | P1 | Deleted from snapshot. |
| `docs/pre-deployment-review-20260903.md` | Pre-deployment review record | P1 | Deleted from snapshot. |
| `docs/code-review-20260903.md` | Historical deployment review context | P1 | Deleted from snapshot. |
| `docs/self-hosted-ci-runner.md` | Runner/host identity | P1 | Rewritten with placeholders and isolation rules. |
| `docs/asset-record.md` | Populated infrastructure metadata | P1 | Replaced with an unpopulated template. |
| `docs/architecture.md` | Current topology and runtime claims | P1 | Rewritten as provider-neutral architecture. |
| `docs/g1-v2-port-ownership-adr.md` | Current port-to-service mapping | P1 | Rewritten as a generic ownership gate. |
| `docs/g1-v2-resilient-global-edge-prd.md` | Incident samples and deployment baseline | P1 | Rewritten as public requirements only. |
| `docs/server-selection-and-cost.md` | Procurement/provider decision context | P2 | Rewritten as a generic selection checklist. |
| `docs/singapore-fixed-edge-recovery.md` | Region-specific filename | P1 | Renamed to `docs/fixed-edge-recovery.md` and generalized. |
| `scripts/singapore-path-diagnose.sh` | Region-specific filename/usage | P1 | Renamed to `scripts/edge-path-diagnose.sh`; references updated. |
| `apps/edge-desktop/src/security.test.ts` | Known historical IP test literal | P0 | Replaced with a documentation-network test value. |
| `.temp/`, `.workbuddy/`, `reports/`, build caches | Local/runtime state | P1 | Excluded; snapshot created from tracked files only. |

No P0 secret material remains in the snapshot after remediation. All findings
require the final snapshot and public-clone scans to remain green.
