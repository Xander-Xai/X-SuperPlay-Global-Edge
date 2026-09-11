import json
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from jsonschema import validate

SERVICE_ROOT = Path(__file__).parents[1]
AGENT_ROOT = SERVICE_ROOT.parents[1] / "tools" / "edge-health-agent"
sys.path.insert(0, str(SERVICE_ROOT))
sys.path.insert(0, str(AGENT_ROOT))

from app import create_server
from evidence.store import EvidenceStore
from models import EvidenceRepository
from runtime.collector import RuntimeStateCollector


def make_evidence(timestamp="2026-09-08T12:00:00.000Z", score=100.0):
    healthy = score >= 99
    return {
        "schema_version": "p12.health-probe.v1",
        "timestamp": timestamp,
        "tcp": {"host": "edge.example", "port": 443, "success": healthy, "latency_ms": 20.0, "error": None},
        "http": {
            "gstatic": {
                "name": "gstatic",
                "url": "https://gstatic.example/204",
                "expected_status": [204],
                "status": 204,
                "success": healthy,
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


STATUS_SCHEMA = {
    "type": "object",
    "required": ["node_id", "overall_status", "health_score", "service_states", "timestamp"],
    "properties": {
        "node_id": {"type": "string"},
        "overall_status": {"type": "string", "enum": ["healthy", "degraded", "unknown"]},
        "health_score": {"type": ["number", "null"]},
        "service_states": {"type": "object", "required": ["wireguard", "xray_reality", "hysteria2"]},
        "timestamp": {"type": ["string", "null"]},
    },
}

SERVICE_SCHEMA = {
    "type": "object",
    "required": ["node_id", "services", "timestamp"],
    "properties": {"node_id": {"type": "string"}, "services": {"type": "object"}, "timestamp": {"type": ["string", "null"]}},
}

CONNECTION_SCHEMA = {
    "type": "object",
    "required": ["node_id", "connection_state", "protocol", "endpoint_metadata", "timestamp"],
    "properties": {
        "node_id": {"type": "string"},
        "connection_state": {"type": "string", "enum": ["connected", "failed", "unknown"]},
        "protocol": {"type": "string"},
        "endpoint_metadata": {"type": "object"},
        "timestamp": {"type": ["string", "null"]},
    },
}


class RuntimeStateTests(unittest.TestCase):
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

    def test_valid_runtime_state_schemas(self):
        self.store.write(make_evidence())
        status, node_status = self.get("/api/v1/node/status")
        self.assertEqual(status, 200)
        validate(node_status, STATUS_SCHEMA)
        self.assertEqual(node_status["overall_status"], "healthy")
        self.assertEqual(set(node_status["service_states"]), {"wireguard", "xray_reality", "hysteria2"})

        status, services = self.get("/api/v1/node/services")
        self.assertEqual(status, 200)
        validate(services, SERVICE_SCHEMA)
        status, connection = self.get("/api/v1/node/connection")
        self.assertEqual(status, 200)
        validate(connection, CONNECTION_SCHEMA)
        self.assertEqual(connection["connection_state"], "connected")
        self.assertEqual(connection["protocol"], "tcp_probe")

    def test_empty_state_is_unknown_and_services_unavailable(self):
        _, node_status = self.get("/api/v1/node/status")
        self.assertEqual(node_status["overall_status"], "unknown")
        self.assertIsNone(node_status["health_score"])
        _, services = self.get("/api/v1/node/services")
        self.assertTrue(all(item["status"] == "unavailable" for item in services["services"].values()))
        _, connection = self.get("/api/v1/node/connection")
        self.assertEqual(connection["connection_state"], "unknown")
        self.assertEqual(connection["protocol"], "unknown")

    def test_corrupted_evidence_is_counted(self):
        day = self.root / "2026-09-08"
        day.mkdir(parents=True)
        (day / "probe-corrupt.json").write_text("{not-json", encoding="utf-8")
        _, node_status = self.get("/api/v1/node/status")
        self.assertEqual(node_status["corrupted_evidence_count"], 1)
        self.assertEqual(node_status["overall_status"], "unknown")

    def test_read_only_node_api_rejects_post(self):
        request = Request(self.base_url + "/api/v1/node/status", method="POST")
        with self.assertRaises(HTTPError) as raised:
            urlopen(request, timeout=2)
        self.assertEqual(raised.exception.code, 405)

    def test_collector_reuses_repository_health_value(self):
        self.store.write(make_evidence(score=75.0))
        repository = EvidenceRepository(self.root)
        state = RuntimeStateCollector(repository).collect()
        self.assertEqual(state.overall_status, "degraded")
        self.assertEqual(state.health_score, 75.0)
        self.assertEqual(state.service_states["xray_reality"].status, "unavailable")


if __name__ == "__main__":
    unittest.main()
