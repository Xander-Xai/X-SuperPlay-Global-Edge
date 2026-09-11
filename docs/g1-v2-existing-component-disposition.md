# Additive component disposition

This public record describes migration rules, not a live deployment.

| Component | Disposition | Boundary |
| --- | --- | --- |
| Baseline WireGuard Compose | `RETAIN` | Keep as the independently testable baseline and rollback plane. |
| Existing validation and health scripts | `RETAIN` | Do not weaken their failure-closed contracts. |
| Transport diagnostics | `EXTEND` | Add labelled, synthetic measurements without changing existing acceptance gates. |
| Optional Reality/Hysteria2 templates | `RETAIN` | Schema-only examples; external identities and ports are required. |
| Recovery helpers | `RETAIN` | Exercise only with explicit operator approval and bounded rollback. |

Transitions to `SUPERSEDE`, `DEPRECATE_AFTER_EVIDENCE`, or
`REMOVE_AFTER_ACCEPTED_MIGRATION` require independent functional, reliability,
and rollback evidence. No such transition is asserted here.
