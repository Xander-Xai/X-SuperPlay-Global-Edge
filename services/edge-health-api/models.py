"""Read models for the local edge-health evidence API."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from jsonschema.exceptions import ValidationError

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
AGENT_ROOT = REPOSITORY_ROOT / "tools" / "edge-health-agent"
if str(AGENT_ROOT) not in sys.path:
    sys.path.insert(0, str(AGENT_ROOT))

from alert.rules import validate_alert  # noqa: E402
from evidence.store import EvidenceStore  # noqa: E402


class EvidenceRepository:
    """Read-only facade over the existing evidence store and alert snapshot."""

    def __init__(self, evidence_root: str | Path | None = None):
        self.store = EvidenceStore(evidence_root or (AGENT_ROOT / "evidence"))

    @property
    def root(self) -> Path:
        return self.store.root

    def valid_records(self) -> tuple[list[dict[str, Any]], int]:
        """Return valid records and the existing store's corrupted-file count."""

        return self.store._load_valid()

    def latest_record(self) -> tuple[dict[str, Any] | None, int]:
        records, corrupted = self.valid_records()
        if not records:
            return None, corrupted
        latest = max(records, key=lambda item: str(item.get("timestamp", "")))
        return latest, corrupted

    def summary(self) -> dict[str, Any]:
        """Delegate summary calculation to the existing EvidenceStore."""

        return self.store.summarize()

    def latest_alert(self) -> tuple[dict[str, Any] | None, str | None]:
        path = self.root / "alert.json"
        if not path.exists():
            return None, None
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(payload, dict):
                raise ValueError("alert root must be an object")
            validate_alert(payload)
        except (OSError, ValueError, TypeError, ValidationError):
            return None, "invalid_alert"
        return payload, None
