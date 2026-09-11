"""Serializable runtime state models."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class ServiceState:
    name: str
    status: str
    reason: str
    source: str = "local_evidence"

    def to_dict(self) -> dict[str, str]:
        return {
            "name": self.name,
            "status": self.status,
            "reason": self.reason,
            "source": self.source,
        }


@dataclass(frozen=True)
class ConnectionState:
    state: str
    protocol: str
    endpoint_metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "connection_state": self.state,
            "protocol": self.protocol,
            "endpoint_metadata": self.endpoint_metadata,
        }


@dataclass(frozen=True)
class RuntimeState:
    node_id: str
    overall_status: str
    health_score: float | None
    service_states: dict[str, ServiceState]
    connection: ConnectionState
    timestamp: str | None
    corrupted_evidence_count: int = 0

    def status_payload(self) -> dict[str, Any]:
        return {
            "node_id": self.node_id,
            "overall_status": self.overall_status,
            "health_score": self.health_score,
            "service_states": {name: state.to_dict() for name, state in self.service_states.items()},
            "timestamp": self.timestamp,
            "corrupted_evidence_count": self.corrupted_evidence_count,
        }

    def services_payload(self) -> dict[str, Any]:
        return {
            "node_id": self.node_id,
            "services": {name: state.to_dict() for name, state in self.service_states.items()},
            "timestamp": self.timestamp,
            "corrupted_evidence_count": self.corrupted_evidence_count,
        }

    def connection_payload(self) -> dict[str, Any]:
        return {
            "node_id": self.node_id,
            **self.connection.to_dict(),
            "timestamp": self.timestamp,
            "corrupted_evidence_count": self.corrupted_evidence_count,
        }
