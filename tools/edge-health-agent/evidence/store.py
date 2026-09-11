"""Append-only local evidence files, summaries, and bounded retention."""

from __future__ import annotations

import json
import math
import os
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Mapping

from jsonschema.exceptions import ValidationError

from probe import validate_evidence


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_timestamp(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError) as exc:
        raise ValueError("evidence timestamp must be an ISO-8601 timestamp") from exc
    if parsed.tzinfo is None:
        raise ValueError("evidence timestamp must include a timezone")
    return parsed.astimezone(timezone.utc)


def _atomic_write_json(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


class EvidenceStore:
    """Persist one probe result per file and derive a local summary.

    The store is intentionally local and passive. It does not alert, recover,
    rotate traffic, or communicate with a server.
    """

    def __init__(self, root: str | Path = "evidence", max_days: int = 7):
        if isinstance(max_days, bool) or int(max_days) < 0:
            raise ValueError("max_days must be a non-negative integer")
        self.root = Path(root)
        self.max_days = int(max_days)

    def _probe_files(self) -> list[Path]:
        if not self.root.exists():
            return []
        return sorted(
            path
            for path in self.root.rglob("probe-*.json")
            if path.is_file() and path.name != "summary.json"
        )

    def write(self, evidence: Mapping[str, Any]) -> Path:
        """Validate and atomically write a timestamped evidence JSON file."""

        validate_evidence(evidence)
        timestamp = _parse_timestamp(str(evidence["timestamp"]))
        day_directory = self.root / timestamp.strftime("%Y-%m-%d")
        stem = f"probe-{timestamp.strftime('%Y%m%dT%H%M%S')}"
        destination = day_directory / f"{stem}.json"
        suffix = 1
        while destination.exists():
            destination = day_directory / f"{stem}-{suffix:02d}.json"
            suffix += 1
        _atomic_write_json(destination, dict(evidence))
        return destination

    def _load_valid(self) -> tuple[list[dict[str, Any]], int]:
        valid: list[dict[str, Any]] = []
        corrupted = 0
        for path in self._probe_files():
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
                if not isinstance(payload, Mapping):
                    raise ValueError("evidence root must be an object")
                validate_evidence(payload)
                valid.append(dict(payload))
            except (OSError, ValueError, TypeError, json.JSONDecodeError, ValidationError):
                corrupted += 1
        return valid, corrupted

    @staticmethod
    def _check_success(evidence: Mapping[str, Any]) -> bool:
        tcp = evidence.get("tcp", {})
        http = evidence.get("http", {})
        egress = evidence.get("egress", {})
        tcp_ok = tcp.get("success") is True
        http_ok = all(item.get("success") is True for item in http.values())
        egress_ok = not egress.get("enabled") or egress.get("success") is True
        return tcp_ok and http_ok and egress_ok

    @staticmethod
    def _latencies(evidence: Mapping[str, Any]) -> list[float]:
        values: list[float] = []
        candidates = [evidence.get("tcp", {}).get("latency_ms")]
        candidates.extend(item.get("latency_ms") for item in evidence.get("http", {}).values())
        for value in candidates:
            if isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0:
                values.append(float(value))
        return values

    @staticmethod
    def _p95(values: list[float]) -> float:
        if not values:
            return 0.0
        ordered = sorted(values)
        index = max(0, math.ceil(len(ordered) * 0.95) - 1)
        return round(ordered[index], 3)

    def summarize(self) -> dict[str, Any]:
        """Summarize valid probe files; corrupted files are excluded and counted."""

        records, corrupted = self._load_valid()
        latencies = [latency for record in records for latency in self._latencies(record)]
        total_checks = len(records)
        success_count = sum(self._check_success(record) for record in records)
        tcp_failures = sum(record["tcp"]["success"] is not True for record in records)
        http_failures = sum(
            sum(item.get("success") is not True for item in record["http"].values())
            for record in records
        )
        return {
            "generated_at": _utc_now().isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "total_checks": total_checks,
            "success_count": success_count,
            "failure_count": total_checks - success_count,
            "success_rate": round(success_count / total_checks * 100, 2) if total_checks else 0.0,
            "tcp_failures": tcp_failures,
            "http_failures": http_failures,
            "average_latency": round(sum(latencies) / len(latencies), 3) if latencies else 0.0,
            "p95_latency": self._p95(latencies),
            "latency_samples": len(latencies),
            "corrupted_evidence_count": corrupted,
        }

    def write_summary(self) -> Path:
        """Write the current summary to ``root/summary.json`` atomically."""

        destination = self.root / "summary.json"
        _atomic_write_json(destination, self.summarize())
        return destination

    def cleanup(self, now: datetime | None = None) -> list[Path]:
        """Delete probe files older than ``max_days`` and remove empty date dirs."""

        current = (now or _utc_now()).astimezone(timezone.utc)
        cutoff = current - timedelta(days=self.max_days)
        removed: list[Path] = []
        for path in self._probe_files():
            modified = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
            if modified < cutoff:
                path.unlink()
                removed.append(path)
        if self.root.exists():
            for directory in sorted((path for path in self.root.rglob("*") if path.is_dir()), reverse=True):
                try:
                    directory.rmdir()
                except OSError:
                    pass
        return removed
