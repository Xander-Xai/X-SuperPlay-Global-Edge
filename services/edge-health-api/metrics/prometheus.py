"""Render existing reliability state as deterministic Prometheus text."""

from __future__ import annotations

import math
from typing import Any

from models import EvidenceRepository
from routes.alerts import get_events
from routes.health import get_history
from routes.node import get_status


METRIC_NAMES = (
    "x_superplay_health_score",
    "x_superplay_http_success_rate",
    "x_superplay_latency_p50_ms",
    "x_superplay_latency_p95_ms",
    "x_superplay_node_status",
    "x_superplay_alert_count",
)

HELP_TEXT = {
    "x_superplay_health_score": "Current health score from the latest valid probe.",
    "x_superplay_http_success_rate": "Historical probe success rate as a percentage.",
    "x_superplay_latency_p50_ms": "Median observed probe latency in milliseconds when available.",
    "x_superplay_latency_p95_ms": "95th percentile observed probe latency in milliseconds.",
    "x_superplay_node_status": "Node status (1 healthy, 0 degraded, NaN unavailable).",
    "x_superplay_alert_count": "Number of currently active alert events.",
}


def _format_value(value: Any) -> str:
    """Format a scalar according to the Prometheus text exposition grammar."""

    if value is None or isinstance(value, bool):
        return "NaN"
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        return "NaN"
    if not math.isfinite(numeric):
        return "NaN"
    if numeric.is_integer():
        return str(int(numeric))
    return format(numeric, ".6f").rstrip("0").rstrip(".")


def _status_value(status: Any) -> float:
    if status == "healthy":
        return 1.0
    if status == "degraded":
        return 0.0
    return math.nan


def render_metrics(
    repository: EvidenceRepository,
    identity_provider: Any | None = None,
) -> str:
    """Return a stable, label-free Prometheus snapshot.

    Values are read from the existing route/model layer. No probe, summary, or
    alert calculation is performed here. Metrics that cannot be observed are
    represented as ``NaN`` rather than an invented zero.
    """

    history = get_history(repository)
    status = get_status(repository, identity_provider)
    events = get_events(repository)
    summary = history.get("historical_summary", {})
    has_samples = isinstance(summary, dict) and summary.get("total_checks", 0) > 0

    current_score = status.get("health_score")
    http_success_rate = history.get("availability") if has_samples else math.nan
    percentiles = history.get("latency_percentiles", {})
    p50 = percentiles.get("p50") if has_samples and isinstance(percentiles, dict) else math.nan
    p95 = percentiles.get("p95") if has_samples and isinstance(percentiles, dict) else math.nan
    alert_count = len(events.get("events", [])) if isinstance(events, dict) else 0

    values = {
        "x_superplay_health_score": current_score,
        "x_superplay_http_success_rate": http_success_rate,
        "x_superplay_latency_p50_ms": p50,
        "x_superplay_latency_p95_ms": p95,
        "x_superplay_node_status": _status_value(status.get("overall_status", "unknown")),
        "x_superplay_alert_count": alert_count,
    }
    lines: list[str] = []
    for name in METRIC_NAMES:
        lines.append(f"# HELP {name} {HELP_TEXT[name]}")
        lines.append(f"# TYPE {name} gauge")
        lines.append(f"{name} {_format_value(values[name])}")
    return "\n".join(lines) + "\n"
