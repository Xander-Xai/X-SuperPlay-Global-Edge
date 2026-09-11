"""Runtime state derivation rules that never mutate the data plane."""

from __future__ import annotations

from typing import Any, Mapping

from runtime.models import ConnectionState, RuntimeState, ServiceState

SERVICE_NAMES = ("wireguard", "xray_reality", "hysteria2")
UNAVAILABLE_REASON = "service_state_not_present_in_local_evidence"


def _service_states() -> dict[str, ServiceState]:
    return {
        name: ServiceState(name=name, status="unavailable", reason=UNAVAILABLE_REASON)
        for name in SERVICE_NAMES
    }


def build_runtime_state(
    node_id: str,
    current: Mapping[str, Any],
    latest: Mapping[str, Any] | None,
    corrupted_evidence_count: int = 0,
) -> RuntimeState:
    """Build the future state contract from already-observed evidence.

    Service states stay unavailable because the current probe schema has no
    WireGuard, Xray/Reality, or Hysteria2 service-state observation. A TCP
    result is intentionally not promoted to a Reality or tunnel result.
    """

    service_states = _service_states()
    if latest is None:
        connection = ConnectionState(state="unknown", protocol="unknown")
        return RuntimeState(
            node_id=node_id,
            overall_status="unknown",
            health_score=None,
            service_states=service_states,
            connection=connection,
            timestamp=None,
            corrupted_evidence_count=corrupted_evidence_count,
        )

    tcp = latest.get("tcp", {})
    tcp_success = tcp.get("success")
    if tcp_success is True:
        connection_state = "connected"
    elif tcp_success is False:
        connection_state = "failed"
    else:
        connection_state = "unknown"
    connection = ConnectionState(
        state=connection_state,
        protocol="tcp_probe",
        endpoint_metadata={"host": tcp.get("host"), "port": tcp.get("port")},
    )
    return RuntimeState(
        node_id=node_id,
        overall_status=str(current.get("node_status", "unknown")),
        health_score=current.get("health_score"),
        service_states=service_states,
        connection=connection,
        timestamp=latest.get("timestamp"),
        corrupted_evidence_count=corrupted_evidence_count,
    )
