#!/usr/bin/env python3
"""Read-only TCP, HTTP, and optional egress health probe.

The CLI performs one bounded observation run and emits JSON evidence. It never
changes routing, services, client configuration, or server state.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener

try:
    import yaml
except ImportError as exc:  # pragma: no cover - exercised by installation failures
    raise RuntimeError("PyYAML is required; install tools/edge-health-agent/requirements.txt") from exc

SCHEMA_VERSION = "p12.health-probe.v1"


class ConfigError(ValueError):
    """Raised when the user-supplied YAML does not describe a probe run."""


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def duration_ms(start: float) -> float:
    return round((time.perf_counter() - start) * 1000, 3)


def _error_text(exc: BaseException) -> str:
    message = str(exc).strip()
    return f"{type(exc).__name__}: {message}" if message else type(exc).__name__


def _as_status_list(value: Any, field: str) -> list[int]:
    if value is None:
        return [200, 204]
    if not isinstance(value, list) or not value:
        raise ConfigError(f"{field} must be a non-empty list of HTTP status codes")
    try:
        statuses = [int(item) for item in value]
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"{field} must contain integer HTTP status codes") from exc
    if any(status < 100 or status > 599 for status in statuses):
        raise ConfigError(f"{field} contains a status outside 100..599")
    return statuses


def load_config(path: str | Path) -> dict[str, Any]:
    """Load and normalize one YAML configuration without contacting the network."""

    config_path = Path(path)
    try:
        raw = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ConfigError(f"cannot read config {config_path}: {exc}") from exc
    except yaml.YAMLError as exc:
        raise ConfigError(f"invalid YAML in {config_path}: {exc}") from exc

    if not isinstance(raw, Mapping):
        raise ConfigError("config root must be a YAML mapping")

    try:
        timeout_seconds = float(raw.get("timeout_seconds", 3.0))
    except (TypeError, ValueError) as exc:
        raise ConfigError("timeout_seconds must be a positive number") from exc
    if timeout_seconds <= 0:
        raise ConfigError("timeout_seconds must be a positive number")

    tcp = raw.get("tcp", {})
    if not isinstance(tcp, Mapping) or not str(tcp.get("host", "")).strip():
        raise ConfigError("tcp.host is required")
    try:
        tcp_port = int(tcp.get("port", 443))
    except (TypeError, ValueError) as exc:
        raise ConfigError("tcp.port must be an integer") from exc
    if not 1 <= tcp_port <= 65535:
        raise ConfigError("tcp.port must be between 1 and 65535")

    http = raw.get("http", {})
    if not isinstance(http, Mapping):
        raise ConfigError("http must be a mapping")
    targets = []
    for index, target in enumerate(http.get("targets", [])):
        if not isinstance(target, Mapping):
            raise ConfigError(f"http.targets[{index}] must be a mapping")
        name = str(target.get("name", "")).strip()
        url = str(target.get("url", "")).strip()
        if not name or not url:
            raise ConfigError(f"http.targets[{index}] requires name and url")
        targets.append(
            {
                "name": name,
                "url": url,
                "expected_status": _as_status_list(
                    target.get("expected_status"), f"http.targets[{index}].expected_status"
                ),
            }
        )

    egress = raw.get("egress", {})
    if not isinstance(egress, Mapping):
        raise ConfigError("egress must be a mapping")
    egress_enabled = bool(egress.get("enabled", False))
    egress_url = str(egress.get("url", "https://api.ipify.org?format=json")).strip()
    proxy = str(egress.get("proxy", "")).strip()
    expected_ip = str(egress.get("expected_ip", "")).strip()
    if egress_enabled and not egress_url:
        raise ConfigError("egress.url is required when egress.enabled is true")

    evidence = raw.get("evidence", {})
    if not isinstance(evidence, Mapping):
        raise ConfigError("evidence must be a mapping")
    evidence_root = str(evidence.get("root", "evidence")).strip() or "evidence"
    try:
        max_days = int(evidence.get("max_days", 7))
    except (TypeError, ValueError) as exc:
        raise ConfigError("evidence.max_days must be a non-negative integer") from exc
    if max_days < 0:
        raise ConfigError("evidence.max_days must be a non-negative integer")

    alerts = raw.get("alerts", {})
    if not isinstance(alerts, Mapping):
        raise ConfigError("alerts must be a mapping")
    try:
        success_rate_threshold = float(alerts.get("success_rate_threshold", 99.0))
        p95_latency_threshold_ms = float(alerts.get("p95_latency_threshold_ms", 3000.0))
        tcp_failure_threshold = int(alerts.get("tcp_failure_threshold", 3))
    except (TypeError, ValueError) as exc:
        raise ConfigError("alert thresholds must be numeric") from exc
    if not 0 <= success_rate_threshold <= 100:
        raise ConfigError("alerts.success_rate_threshold must be between 0 and 100")
    if p95_latency_threshold_ms < 0 or tcp_failure_threshold < 0:
        raise ConfigError("alert latency and failure thresholds must be non-negative")
    summary_path = str(alerts.get("summary_path", "")).strip() or str(Path(evidence_root) / "summary.json")
    output_path = str(alerts.get("output_path", "")).strip() or str(Path(evidence_root) / "alert.json")

    return {
        "timeout_seconds": timeout_seconds,
        "tcp": {"host": str(tcp["host"]).strip(), "port": tcp_port},
        "http": {"targets": targets},
        "egress": {
            "enabled": egress_enabled,
            "url": egress_url,
            "expected_ip": expected_ip,
            "proxy": proxy,
        },
        "evidence": {"root": evidence_root, "max_days": max_days},
        "alerts": {
            "summary_path": summary_path,
            "output_path": output_path,
            "success_rate_threshold": success_rate_threshold,
            "p95_latency_threshold_ms": p95_latency_threshold_ms,
            "tcp_failure_threshold": tcp_failure_threshold,
        },
    }


def probe_tcp(host: str, port: int, timeout_seconds: float = 3.0) -> dict[str, Any]:
    """Attempt one TCP connection and close it immediately after connect."""

    started = time.perf_counter()
    result: dict[str, Any] = {
        "host": host,
        "port": port,
        "success": False,
        "latency_ms": None,
        "error": None,
    }
    try:
        with socket.create_connection((host, port), timeout=timeout_seconds):
            result["success"] = True
    except (socket.timeout, TimeoutError) as exc:
        result["error"] = f"CONNECT_TIMEOUT: {_error_text(exc)}"
    except ConnectionRefusedError as exc:
        result["error"] = f"CONNECTION_REFUSED: {_error_text(exc)}"
    except OSError as exc:
        result["error"] = f"TCP_ERROR: {_error_text(exc)}"
    finally:
        result["latency_ms"] = duration_ms(started)
    return result


def make_opener(proxy: str = ""):
    """Build an opener; an empty proxy explicitly disables environment proxies."""

    handlers = [ProxyHandler({})] if not proxy else [ProxyHandler({"http": proxy, "https": proxy})]
    return build_opener(*handlers)


def probe_http_target(
    target: Mapping[str, Any], timeout_seconds: float = 3.0, opener: Any | None = None
) -> dict[str, Any]:
    """Run one bounded HTTP request and retain status/timing/error evidence."""

    started = time.perf_counter()
    expected_status = list(target["expected_status"])
    result: dict[str, Any] = {
        "name": target["name"],
        "url": target["url"],
        "expected_status": expected_status,
        "status": None,
        "success": False,
        "latency_ms": None,
        "error": None,
    }
    request = Request(
        target["url"],
        headers={"User-Agent": "X-SuperPlay-edge-health-agent/0.1", "Accept": "*/*"},
        method="GET",
    )
    active_opener = opener or make_opener()
    try:
        with active_opener.open(request, timeout=timeout_seconds) as response:
            result["status"] = int(response.getcode())
            response.read(1024)
            result["success"] = result["status"] in expected_status
            if not result["success"]:
                result["error"] = f"HTTP_STATUS_{result['status']}"
    except HTTPError as exc:
        result["status"] = int(exc.code)
        result["error"] = f"HTTP_STATUS_{exc.code}"
    except (URLError, TimeoutError, socket.timeout, OSError) as exc:
        result["error"] = _error_text(exc)
    finally:
        result["latency_ms"] = duration_ms(started)
    return result


def _extract_ip(body: str) -> str | None:
    """Extract one IPv4/IPv6 value from common plain-text or JSON echo bodies."""

    candidates: list[Any] = []
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        payload = None
    if isinstance(payload, Mapping):
        for key in ("ip", "origin", "address", "public_ip", "query"):
            if key in payload:
                candidates.append(payload[key])
    candidates.append(body.strip())
    for candidate in candidates:
        for item in str(candidate).split(","):
            value = item.strip()
            try:
                return str(ipaddress.ip_address(value))
            except ValueError:
                continue
    match = re.search(r"(?<![0-9a-fA-F:])(?:[0-9]{1,3}(?:\.[0-9]{1,3}){3}|[0-9a-fA-F:]{2,})", body)
    if match:
        try:
            return str(ipaddress.ip_address(match.group(0)))
        except ValueError:
            return None
    return None


def probe_egress(
    config: Mapping[str, Any], timeout_seconds: float = 3.0, opener: Any | None = None
) -> dict[str, Any]:
    """Query the configured IP echo endpoint, optionally through a proxy."""

    enabled = bool(config.get("enabled", False))
    result: dict[str, Any] = {
        "enabled": enabled,
        "url": config.get("url", ""),
        "expected_ip": config.get("expected_ip", ""),
        "observed_ip": None,
        "match": False,
        "success": False,
        "status": "UNAVAILABLE" if not enabled else "FAIL",
        "latency_ms": None,
        "proxy_configured": bool(config.get("proxy", "")),
        "error": "disabled" if not enabled else None,
    }
    if not enabled:
        return result
    if not result["expected_ip"]:
        result["status"] = "CONFIG_ERROR"
        result["error"] = "expected_ip_not_configured"
        return result

    started = time.perf_counter()
    request = Request(
        result["url"],
        headers={"User-Agent": "X-SuperPlay-edge-health-agent/0.1", "Accept": "application/json,text/plain"},
        method="GET",
    )
    active_opener = opener or make_opener(str(config.get("proxy", "")))
    try:
        with active_opener.open(request, timeout=timeout_seconds) as response:
            body = response.read(4096).decode("utf-8", errors="replace")
        result["observed_ip"] = _extract_ip(body)
        if result["observed_ip"] is None:
            result["error"] = "EGRESS_RESPONSE_INVALID"
        else:
            result["match"] = result["observed_ip"] == result["expected_ip"]
            result["success"] = bool(result["match"])
            result["status"] = "PASS" if result["success"] else "FAIL"
            if not result["success"]:
                result["error"] = "EGRESS_IP_MISMATCH"
    except HTTPError as exc:
        result["error"] = f"HTTP_STATUS_{exc.code}"
    except (URLError, TimeoutError, socket.timeout, OSError) as exc:
        result["error"] = _error_text(exc)
    finally:
        result["latency_ms"] = duration_ms(started)
    return result


def calculate_health_score(
    tcp: Mapping[str, Any], http: Mapping[str, Mapping[str, Any]], egress: Mapping[str, Any]
) -> float:
    """Calculate an MVP score from enabled, observed components only.

    TCP contributes 40 points, HTTP target success rate contributes 40 points,
    and configured egress comparison contributes 20 points. Disabled egress and
    an empty HTTP target list are excluded rather than counted as failures.
    """

    weighted_score = 0.0
    weight_total = 0.0
    weighted_score += 40.0 if tcp.get("success") else 0.0
    weight_total += 40.0
    if http:
        weighted_score += 40.0 * (sum(bool(item.get("success")) for item in http.values()) / len(http))
        weight_total += 40.0
    if egress.get("enabled"):
        weighted_score += 20.0 if egress.get("success") else 0.0
        weight_total += 20.0
    return round(weighted_score / weight_total * 100, 2) if weight_total else 0.0


def run_probe(config: Mapping[str, Any]) -> dict[str, Any]:
    """Execute one observation run and return JSON-serializable evidence."""

    timeout_seconds = float(config["timeout_seconds"])
    tcp = probe_tcp(config["tcp"]["host"], config["tcp"]["port"], timeout_seconds)
    http_results = {
        target["name"]: probe_http_target(target, timeout_seconds)
        for target in config["http"]["targets"]
    }
    egress = probe_egress(config["egress"], timeout_seconds)
    evidence = {
        "schema_version": SCHEMA_VERSION,
        "timestamp": utc_timestamp(),
        "tcp": tcp,
        "http": http_results,
        "egress": egress,
        "health_score": calculate_health_score(tcp, http_results, egress),
    }
    validate_evidence(evidence)
    return evidence


EVIDENCE_SCHEMA: dict[str, Any] = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "required": ["schema_version", "timestamp", "tcp", "http", "egress", "health_score"],
    "additionalProperties": False,
    "properties": {
        "schema_version": {"type": "string"},
        "timestamp": {"type": "string", "minLength": 1},
        "tcp": {
            "type": "object",
            "required": ["host", "port", "success", "latency_ms", "error"],
            "additionalProperties": False,
            "properties": {
                "host": {"type": "string"},
                "port": {"type": "integer", "minimum": 1, "maximum": 65535},
                "success": {"type": "boolean"},
                "latency_ms": {"type": ["number", "null"], "minimum": 0},
                "error": {"type": ["string", "null"]},
            },
        },
        "http": {
            "type": "object",
            "additionalProperties": {
                "type": "object",
                "required": ["name", "url", "expected_status", "status", "success", "latency_ms", "error"],
                "additionalProperties": False,
                "properties": {
                    "name": {"type": "string"},
                    "url": {"type": "string"},
                    "expected_status": {"type": "array", "items": {"type": "integer"}},
                    "status": {"type": ["integer", "null"]},
                    "success": {"type": "boolean"},
                    "latency_ms": {"type": ["number", "null"], "minimum": 0},
                    "error": {"type": ["string", "null"]},
                },
            },
        },
        "egress": {
            "type": "object",
            "required": [
                "enabled",
                "url",
                "expected_ip",
                "observed_ip",
                "match",
                "success",
                "status",
                "latency_ms",
                "proxy_configured",
                "error",
            ],
            "additionalProperties": False,
            "properties": {
                "enabled": {"type": "boolean"},
                "url": {"type": "string"},
                "expected_ip": {"type": "string"},
                "observed_ip": {"type": ["string", "null"]},
                "match": {"type": "boolean"},
                "success": {"type": "boolean"},
                "status": {"type": "string", "enum": ["PASS", "FAIL", "UNAVAILABLE", "CONFIG_ERROR"]},
                "latency_ms": {"type": ["number", "null"], "minimum": 0},
                "proxy_configured": {"type": "boolean"},
                "error": {"type": ["string", "null"]},
            },
        },
        "health_score": {"type": "number", "minimum": 0, "maximum": 100},
    },
}


def validate_evidence(evidence: Mapping[str, Any]) -> None:
    """Validate an evidence object against the stable MVP JSON schema."""

    try:
        from jsonschema import validate
    except ImportError as exc:  # pragma: no cover - exercised by installation failures
        raise RuntimeError("jsonschema is required; install requirements.txt") from exc
    validate(instance=dict(evidence), schema=EVIDENCE_SCHEMA)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run one read-only edge health observation")
    parser.add_argument("--config", help="YAML probe configuration")
    parser.add_argument("--output", help="optional JSON output file; stdout is always emitted")
    parser.add_argument(
        "--output-evidence",
        nargs="?",
        const="",
        default=None,
        metavar="DIR",
        help="persist evidence and summary under DIR (default: evidence from config)",
    )
    parser.add_argument(
        "--evaluate-alert",
        action="store_true",
        help="evaluate the configured summary and write alert.json without probing",
    )
    args = parser.parse_args(argv)
    if not args.config and not args.evaluate_alert:
        parser.error("--config is required unless --evaluate-alert uses config.example.yaml")
    if args.evaluate_alert and args.output_evidence is not None:
        parser.error("--evaluate-alert cannot be combined with --output-evidence")
    config_path = args.config or str(Path(__file__).with_name("config.example.yaml"))
    try:
        config = load_config(config_path)
    except (ConfigError, OSError, RuntimeError) as exc:
        parser.error(str(exc))

    if args.evaluate_alert:
        from alert.rules import evaluate_summary_file, write_alert

        summary_path = config["alerts"]["summary_path"]
        output_path = config["alerts"]["output_path"]
        if not args.config:
            config_directory = Path(config_path).parent
            if not Path(summary_path).is_absolute():
                summary_path = str(config_directory / summary_path)
            if not Path(output_path).is_absolute():
                output_path = str(config_directory / output_path)
        try:
            alert = evaluate_summary_file(
                summary_path,
                thresholds=config["alerts"],
            )
            alert_path = write_alert(output_path, alert)
        except (OSError, ValueError, RuntimeError) as exc:
            parser.error(f"cannot evaluate alert: {exc}")
        rendered = json.dumps(alert, ensure_ascii=False, indent=2, sort_keys=True)
        if args.output:
            output_path = Path(args.output)
            try:
                output_path.write_text(rendered + "\n", encoding="utf-8")
            except OSError as exc:
                parser.error(f"cannot write output {output_path}: {exc}")
        print(rendered)
        print(f"alert_path={alert_path}", file=sys.stderr)
        return 0

    try:
        evidence = run_probe(config)
    except (ConfigError, OSError, RuntimeError) as exc:
        parser.error(str(exc))
    stored_path = None
    summary_path = None
    if args.output_evidence is not None:
        from evidence.store import EvidenceStore

        evidence_root = args.output_evidence or config["evidence"]["root"]
        try:
            store = EvidenceStore(evidence_root, max_days=config["evidence"]["max_days"])
            stored_path = store.write(evidence)
            store.cleanup()
            summary_path = store.write_summary()
        except (OSError, ValueError, RuntimeError) as exc:
            parser.error(f"cannot persist evidence: {exc}")

    rendered = json.dumps(evidence, ensure_ascii=False, indent=2, sort_keys=True)
    if args.output:
        output_path = Path(args.output)
        try:
            output_path.write_text(rendered + "\n", encoding="utf-8")
        except OSError as exc:
            parser.error(f"cannot write output {output_path}: {exc}")
    print(rendered)
    if stored_path is not None:
        print(f"evidence_path={stored_path}", file=sys.stderr)
        print(f"summary_path={summary_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
