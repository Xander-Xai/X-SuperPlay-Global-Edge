"""Evidence-backed health payloads."""

from __future__ import annotations

from typing import Any

from models import EvidenceRepository


def current_health(repository: EvidenceRepository) -> dict[str, Any]:
    latest, corrupted = repository.latest_record()
    if latest is None:
        return {
            "node_status": "unknown",
            "health_score": None,
            "latest_metrics": {},
            "timestamp": None,
            "corrupted_evidence_count": corrupted,
        }
    score = latest.get("health_score")
    if isinstance(score, (int, float)) and score >= 99:
        node_status = "healthy"
    else:
        node_status = "degraded"
    return {
        "node_status": node_status,
        "health_score": score,
        "latest_metrics": {
            "tcp": latest.get("tcp", {}),
            "http": latest.get("http", {}),
            "egress": latest.get("egress", {}),
        },
        "timestamp": latest.get("timestamp"),
        "corrupted_evidence_count": corrupted,
    }
def health_history(repository: EvidenceRepository) -> dict[str, Any]:
    summary = repository.summary()
    return {
        "availability": summary.get("success_rate", 0.0),
        "latency_percentiles": {"p95": summary.get("p95_latency", 0.0)},
        "historical_summary": summary,
    }
