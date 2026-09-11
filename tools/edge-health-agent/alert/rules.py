"""Deterministic local rules for evaluating an evidence summary."""

from __future__ import annotations

import json
import math
import os
import tempfile
from pathlib import Path
from typing import Any, Mapping

DEFAULT_THRESHOLDS = {
    "success_rate_threshold": 99.0,
    "p95_latency_threshold_ms": 3000.0,
    "tcp_failure_threshold": 3,
}

SUMMARY_FIELDS = ("success_rate", "p95_latency", "tcp_failures")

ALERT_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "required": ["timestamp", "level", "reason", "metric", "value", "threshold", "source_evidence"],
    "additionalProperties": False,
    "properties": {
        "timestamp": {"type": "string", "minLength": 1},
        "level": {"type": "string", "enum": ["NONE", "WARNING", "CRITICAL"]},
        "reason": {"type": "string", "minLength": 1},
        "metric": {"type": "string"},
        "value": {"type": ["number", "null"]},
        "threshold": {"type": ["number", "null"]},
        "source_evidence": {"type": "string", "minLength": 1},
    },
}


class SummaryError(ValueError):
    """Raised when summary input cannot be evaluated safely."""


def _finite_number(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SummaryError(f"summary.{field} must be numeric")
    numeric = float(value)
    if not math.isfinite(numeric):
        raise SummaryError(f"summary.{field} must be finite")
    return numeric


def _thresholds(values: Mapping[str, Any] | None) -> dict[str, float]:
    raw = dict(DEFAULT_THRESHOLDS)
    if values:
        for key in raw:
            if key in values:
                raw[key] = values[key]
    success_rate = _finite_number(raw["success_rate_threshold"], "success_rate_threshold")
    p95_latency = _finite_number(raw["p95_latency_threshold_ms"], "p95_latency_threshold_ms")
    tcp_failures = _finite_number(raw["tcp_failure_threshold"], "tcp_failure_threshold")
    if not 0 <= success_rate <= 100:
        raise ValueError("success_rate_threshold must be between 0 and 100")
    if p95_latency < 0 or tcp_failures < 0:
        raise ValueError("latency and TCP failure thresholds must be non-negative")
    return {
        "success_rate_threshold": success_rate,
        "p95_latency_threshold_ms": p95_latency,
        "tcp_failure_threshold": tcp_failures,
    }


def _summary_timestamp(summary: Mapping[str, Any]) -> str:
    timestamp = summary.get("generated_at") or summary.get("timestamp")
    if not isinstance(timestamp, str) or not timestamp.strip():
        raise SummaryError("summary.generated_at is required for reproducible alert timestamp")
    return timestamp


def _validate_summary(summary: Mapping[str, Any]) -> None:
    for field in SUMMARY_FIELDS:
        if field not in summary:
            raise SummaryError(f"summary.{field} is required")
        value = _finite_number(summary[field], field)
        if value < 0:
            raise SummaryError(f"summary.{field} must be non-negative")
    if _finite_number(summary["success_rate"], "success_rate") > 100:
        raise SummaryError("summary.success_rate must be at most 100")
    _summary_timestamp(summary)


def _alert(
    timestamp: str,
    level: str,
    reason: str,
    metric: str,
    value: float | None,
    threshold: float | None,
    source_evidence: str,
) -> dict[str, Any]:
    return {
        "timestamp": timestamp,
        "level": level,
        "reason": reason,
        "metric": metric,
        "value": value,
        "threshold": threshold,
        "source_evidence": source_evidence,
    }


def evaluate_summary(
    summary: Mapping[str, Any],
    thresholds: Mapping[str, Any] | None = None,
    source_evidence: str = "summary.json",
) -> dict[str, Any]:
    """Evaluate one validated summary with critical-before-warning precedence."""

    if not isinstance(summary, Mapping):
        raise SummaryError("summary root must be an object")
    _validate_summary(summary)
    limits = _thresholds(thresholds)
    timestamp = _summary_timestamp(summary)
    tcp_failures = _finite_number(summary["tcp_failures"], "tcp_failures")
    success_rate = _finite_number(summary["success_rate"], "success_rate")
    p95_latency = _finite_number(summary["p95_latency"], "p95_latency")

    if tcp_failures > limits["tcp_failure_threshold"]:
        return _alert(
            timestamp,
            "CRITICAL",
            "tcp failure count above threshold",
            "tcp_failures",
            tcp_failures,
            limits["tcp_failure_threshold"],
            source_evidence,
        )
    if success_rate < limits["success_rate_threshold"]:
        return _alert(
            timestamp,
            "WARNING",
            "success_rate below threshold",
            "success_rate",
            success_rate,
            limits["success_rate_threshold"],
            source_evidence,
        )
    if p95_latency > limits["p95_latency_threshold_ms"]:
        return _alert(
            timestamp,
            "WARNING",
            "p95 latency above threshold",
            "p95_latency",
            p95_latency,
            limits["p95_latency_threshold_ms"],
            source_evidence,
        )
    return _alert(timestamp, "NONE", "no alert rule fired", "", None, None, source_evidence)


def evaluate_summary_file(
    summary_path: str | Path,
    thresholds: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Read one summary JSON and evaluate it without touching the network."""

    path = Path(summary_path)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise SummaryError(f"cannot read summary {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise SummaryError(f"invalid JSON in summary {path}: {exc}") from exc
    return evaluate_summary(payload, thresholds=thresholds, source_evidence=str(path))


def validate_alert(alert: Mapping[str, Any]) -> None:
    try:
        from jsonschema import validate
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError("jsonschema is required; install requirements.txt") from exc
    validate(instance=dict(alert), schema=ALERT_SCHEMA)


def write_alert(path: str | Path, alert: Mapping[str, Any]) -> Path:
    """Validate and atomically write deterministic alert JSON."""

    validate_alert(alert)
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(dict(alert), ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    fd, temporary_name = tempfile.mkstemp(prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, destination)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()
    return destination
