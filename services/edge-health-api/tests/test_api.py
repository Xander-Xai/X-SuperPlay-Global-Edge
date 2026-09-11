import json
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.request import Request, urlopen

from jsonschema import validate

SERVICE_ROOT = Path(__file__).parents[1]
AGENT_ROOT = SERVICE_ROOT.parents[1] / "tools" / "edge-health-agent"
sys.path.insert(0, str(SERVICE_ROOT))
sys.path.insert(0, str(AGENT_ROOT))

from alert.rules import write_alert
from evidence.store import EvidenceStore
from app import create_server


def make_evidence(timestamp="2026-09-08T12:00:00.000Z", score=100.0):
    return {
        "schema_version": "p12.health-probe.v1",
        "timestamp": timestamp,
        "tcp": {"host": "edge.example", "port": 443, "success": score >= 99, "latency_ms": 20.0, "error": None},
        "http": {
            "gstatic": {
                "name": "gstatic",
                "url": "https://gstatic.example/204",
                "expected_status": [204],
                "status": 204,
                "success": score >= 99,
                "latency_ms": 40.0,
                "error": None,
            }
        },
        "egress": {
            "enabled": False,
            "url": "https://ip.example/",
            "expected_ip": "",
            "observed_ip": None,
            "match": False,
            "success": False,
            "status": "UNAVAILABLE",
            "latency_ms": None,
            "proxy_configured": False,
            "error": "disabled",
        },
        "health_score": score,
    }


CURRENT_SCHEMA = {
    "type": "object",
    "required": ["node_status", "health_score", "latest_metrics", "timestamp", "corrupted_evidence_count"],
    "properties": {
        "node_status": {"type": "string", "enum": ["healthy", "degraded", "unknown"]},
        "health_score": {"type": ["number", "null"]},
        "latest_metrics": {"type": "object"},
        "timestamp": {"type": ["string", "null"]},
        "corrupted_evidence_count": {"type": "integer", "minimum": 0},
    },
}

HISTORY_SCHEMA = {
    "type": "object",
    "required": ["availability", "latency_percentiles", "historical_summary"],
    "properties": {
        "availability": {"type": "number"},
        "latency_percentiles": {"type": "object", "required": ["p95"]},
        "historical_summary": {"type": "object"},
    },
}

EVENTS_SCHEMA = {
    "type": "object",
    "required": ["events", "resolved"],
    "properties": {
        "events": {"type": "array"},
        "resolved": {"type": ["boolean", "null"]},
    },
}


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.store = EvidenceStore(self.root)
        self.server = create_server("127.0.0.1", 0, self.root)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.tempdir.cleanup()

    def get(self, path):
        with urlopen(self.base_url + path, timeout=2) as response:
            return response.status, json.loads(response.read().decode("utf-8"))

    def test_api_starts_and_current_response_matches_schema(self):
        self.store.write(make_evidence())
        status, payload = self.get("/api/v1/health/current")
        self.assertEqual(status, 200)
        validate(payload, CURRENT_SCHEMA)
        self.assertEqual(payload["node_status"], "healthy")
        self.assertEqual(payload["health_score"], 100.0)
        self.assertEqual(payload["timestamp"], "2026-09-08T12:00:00.000Z")

    def test_empty_evidence_is_explicitly_unknown(self):
        status, current = self.get("/api/v1/health/current")
        self.assertEqual(status, 200)
        self.assertEqual(current["node_status"], "unknown")
        self.assertIsNone(current["health_score"])
        self.assertEqual(current["latest_metrics"], {})
        status, history = self.get("/api/v1/health/history")
        self.assertEqual(status, 200)
        validate(history, HISTORY_SCHEMA)
        self.assertEqual(history["availability"], 0.0)
        self.assertEqual(history["historical_summary"]["total_checks"], 0)

    def test_corrupted_evidence_is_reported_not_served(self):
        day = self.root / "2026-09-08"
        day.mkdir(parents=True)
        (day / "probe-corrupt.json").write_text("{not-json", encoding="utf-8")
        status, current = self.get("/api/v1/health/current")
        self.assertEqual(status, 200)
        self.assertEqual(current["node_status"], "unknown")
        self.assertEqual(current["corrupted_evidence_count"], 1)
        status, history = self.get("/api/v1/health/history")
        self.assertEqual(status, 200)
        self.assertEqual(history["historical_summary"]["corrupted_evidence_count"], 1)

    def test_alert_retrieval_returns_warning_and_resolved_state(self):
        alert = {
            "timestamp": "2026-09-08T12:00:00.000Z",
            "level": "WARNING",
            "reason": "success_rate below threshold",
            "metric": "success_rate",
            "value": 98.0,
            "threshold": 99.0,
            "source_evidence": "summary.json",
        }
        write_alert(self.root / "alert.json", alert)
        status, payload = self.get("/api/v1/events")
        self.assertEqual(status, 200)
        validate(payload, EVENTS_SCHEMA)
        self.assertFalse(payload["resolved"])
        self.assertEqual(payload["events"][0]["level"], "WARNING")
        self.assertFalse(payload["events"][0]["resolved"])

        resolved = dict(alert)
        resolved.update({"level": "NONE", "reason": "no alert rule fired", "metric": "", "value": None, "threshold": None})
        write_alert(self.root / "alert.json", resolved)
        status, payload = self.get("/api/v1/events")
        self.assertEqual(status, 200)
        validate(payload, EVENTS_SCHEMA)
        self.assertTrue(payload["resolved"])
        self.assertEqual(payload["events"], [])

    def test_post_is_rejected_by_read_only_api(self):
        request = Request(self.base_url + "/api/v1/events", method="POST")
        with self.assertRaises(Exception) as raised:
            urlopen(request, timeout=2)
        self.assertIn("HTTP Error 405", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
