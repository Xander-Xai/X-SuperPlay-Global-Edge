"""Health endpoint route handlers."""

from __future__ import annotations

from typing import Any

from models import EvidenceRepository
from routes.evidence import current_health, health_history


def get_current(repository: EvidenceRepository) -> dict[str, Any]:
    return current_health(repository)


def get_history(repository: EvidenceRepository) -> dict[str, Any]:
    return health_history(repository)
