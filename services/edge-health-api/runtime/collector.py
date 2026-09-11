"""Read-only runtime state collector."""

from __future__ import annotations

from typing import Any

from models import EvidenceRepository
from routes.evidence import current_health
from runtime.models import RuntimeState
from runtime.state import build_runtime_state


class RuntimeStateCollector:
    """Collect one runtime state snapshot from the existing evidence facade."""

    def __init__(self, repository: EvidenceRepository, node_id: str = "edge-current"):
        self.repository = repository
        self.node_id = node_id

    def collect(self) -> RuntimeState:
        latest, corrupted = self.repository.latest_record()
        current = current_health(self.repository)
        return build_runtime_state(self.node_id, current, latest, corrupted)

    def collect_payloads(self) -> dict[str, dict[str, Any]]:
        state = self.collect()
        return {
            "status": state.status_payload(),
            "services": state.services_payload(),
            "connection": state.connection_payload(),
        }
