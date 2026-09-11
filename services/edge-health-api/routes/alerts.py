"""Alert event route handler."""

from __future__ import annotations

from typing import Any

from models import EvidenceRepository


def get_events(repository: EvidenceRepository) -> dict[str, Any]:
    alert, error = repository.latest_alert()
    if error:
        return {"events": [], "resolved": None, "error": error}
    if alert is None:
        return {"events": [], "resolved": True, "timestamp": None}
    resolved = alert.get("level") == "NONE"
    event = dict(alert)
    event["resolved"] = resolved
    return {
        "events": [] if resolved else [event],
        "resolved": resolved,
        "timestamp": alert.get("timestamp"),
    }
