#!/usr/bin/env python3
"""Local read-only HTTP API for edge health evidence."""

from __future__ import annotations

import argparse
import json
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from identity.provider import IdentityConfigError, NodeIdentityProvider
from models import EvidenceRepository
from routes.alerts import get_events
from routes.health import get_current, get_history
from routes.node import (
    get_capabilities,
    get_connection,
    get_identity,
    get_metadata,
    get_services,
    get_status,
)
from metrics.prometheus import render_metrics


def _health_current(repository, _identity):
    return get_current(repository)


def _health_history(repository, _identity):
    return get_history(repository)


def _events(repository, _identity):
    return get_events(repository)


def _node_status(repository, identity):
    return get_status(repository, identity)


def _node_services(repository, identity):
    return get_services(repository, identity)


def _node_connection(repository, identity):
    return get_connection(repository, identity)


def _identity(_repository, identity):
    return get_identity(identity)


def _capabilities(_repository, identity):
    return get_capabilities(identity)


def _metadata(_repository, identity):
    return get_metadata(identity)


def _metrics(repository, identity):
    return render_metrics(repository, identity)


ROUTES = {
    "/api/v1/health/current": _health_current,
    "/api/v1/health/history": _health_history,
    "/api/v1/events": _events,
    "/api/v1/node/status": _node_status,
    "/api/v1/node/services": _node_services,
    "/api/v1/node/connection": _node_connection,
    "/api/v1/node/identity": _identity,
    "/api/v1/node/capabilities": _capabilities,
    "/api/v1/node/metadata": _metadata,
    "/metrics": _metrics,
}


def make_handler(
    repository: EvidenceRepository, identity_provider: NodeIdentityProvider | None = None
):
    if identity_provider is None:
        identity_provider = NodeIdentityProvider(Path(__file__).parent / "config" / "node.yaml")

    class EdgeHealthHandler(BaseHTTPRequestHandler):
        server_version = "EdgeHealthAPI/0.1"

        def _send_json(self, status: int, payload: dict):
            body = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _send_text(self, status: int, body_text: str):
            body = body_text.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):  # noqa: N802 - stdlib handler API
            path = urlsplit(self.path).path
            route = ROUTES.get(path)
            if route is None:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
                return
            try:
                payload = route(repository, identity_provider)
                if path == "/metrics":
                    self._send_text(HTTPStatus.OK, payload)
                else:
                    self._send_json(HTTPStatus.OK, payload)
            except (OSError, ValueError, TypeError) as exc:
                self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(exc)})

        def do_POST(self):  # noqa: N802 - explicit read-only boundary
            self._send_json(HTTPStatus.METHOD_NOT_ALLOWED, {"error": "read_only"})

        def log_message(self, format, *args):  # noqa: A002 - stdlib handler API
            return

    return EdgeHealthHandler


def create_server(
    host: str = "127.0.0.1",
    port: int = 8080,
    evidence_root: str | Path | None = None,
    identity_config: str | Path | None = None,
):
    """Create, but do not start, a local read-only API server."""

    repository = EvidenceRepository(evidence_root)
    config_path = identity_config or Path(__file__).parent / "config" / "node.yaml"
    identity_provider = NodeIdentityProvider(config_path)
    return ThreadingHTTPServer((host, port), make_handler(repository, identity_provider))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run the read-only edge health API")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--evidence-root", type=Path)
    parser.add_argument("--identity-config", type=Path)
    args = parser.parse_args(argv)
    try:
        server = create_server(args.host, args.port, args.evidence_root, args.identity_config)
    except IdentityConfigError as exc:
        parser.error(str(exc))
    print(f"edge-health-api listening on http://{args.host}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
