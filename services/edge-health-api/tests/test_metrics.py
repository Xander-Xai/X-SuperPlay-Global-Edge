import re
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

SERVICE_ROOT = Path(__file__).parents[1]
AGENT_ROOT = SERVICE_ROOT.parents[1] / "tools" / "edge-health-agent"
sys.path.insert(0, str(SERVICE_ROOT))
sys.path.insert(0, str(AGENT_ROOT))

from alert.rules import write_alert
from app import create_server
from evidence.store import EvidenceStore


def make_evidence(timestamp="2026-09-08T12:00:00.000Z", score=100.0):
    success = score >= 99
    return {
        "schema_version": "p12.health-probe.v1",
        "timestamp": timestamp,
        "tcp": {
            "host": "edge.example",
            "port": 443,
            "success": success,
            "latency_ms": 20.0,
            "error": None,
        },
        "http": {
            "gstatic": {
                "name": "gstatic",
                "url": "https://gstatic.example/204",
                "expected_status": [204],
                "status": 204,
                "success": success,
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


METRIC_LINE = re.compile(
    r"^(x_superplay_[a-z0-9_]+) (NaN|[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)$"
)
REQUIRED = {
    "x_superplay_health_score",
    "x_superplay_http_success_rate",
    "x_superplay_latency_p50_ms",
    "x_superplay_latency_p95_ms",
    "x_superplay_node_status",
    "x_superplay_alert_count",
}


def parse_metrics(text):
    samples = {}
    for line in text.splitlines():
        if line.startswith("# "):
            continue
        match = METRIC_LINE.fullmatch(line)
        if not match:
            raise AssertionError(f"invalid Prometheus sample: {line!r}")
        samples[match.group(1)] = match.group(2)
    return samples


class MetricsTests(unittest.TestCase):
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

    def get_metrics(self):
        with urlopen(self.base_url + "/metrics", timeout=2) as response:
            return response.status, response.headers, response.read().decode("utf-8")

    def test_metrics_endpoint_and_prometheus_format(self):
        self.store.write(make_evidence())
        status, headers, body = self.get_metrics()
        self.assertEqual(status, 200)
        self.assertIn("text/plain", headers.get_content_type())
        samples = parse_metrics(body)
        self.assertEqual(set(samples), REQUIRED)
        self.assertEqual(samples["x_superplay_health_score"], "100")
        self.assertEqual(samples["x_superplay_http_success_rate"], "100")
        self.assertEqual(samples["x_superplay_latency_p95_ms"], "40")

    def test_empty_evidence_uses_nan_for_unavailable_values(self):
        _, _, body = self.get_metrics()
        samples = parse_metrics(body)
        self.assertEqual(samples["x_superplay_health_score"], "NaN")
        self.assertEqual(samples["x_superplay_http_success_rate"], "NaN")
        self.assertEqual(samples["x_superplay_latency_p50_ms"], "NaN")
        self.assertEqual(samples["x_superplay_latency_p95_ms"], "NaN")
        self.assertEqual(samples["x_superplay_node_status"], "NaN")
        self.assertEqual(samples["x_superplay_alert_count"], "0")

    def test_corrupted_evidence_and_alert_are_unavailable_without_invention(self):
        day = self.root / "2026-09-08"
        day.mkdir(parents=True)
        (day / "probe-corrupt.json").write_text("{not-json", encoding="utf-8")
        (self.root / "alert.json").write_text("{not-json", encoding="utf-8")
        _, _, body = self.get_metrics()
        samples = parse_metrics(body)
        self.assertEqual(samples["x_superplay_health_score"], "NaN")
        self.assertEqual(samples["x_superplay_node_status"], "NaN")
        self.assertEqual(samples["x_superplay_alert_count"], "0")

    def test_active_alert_count_is_exported(self):
        self.store.write(make_evidence(score=98.0))
        write_alert(
            self.root / "alert.json",
            {
                "timestamp": "2026-09-08T12:00:00.000Z",
                "level": "WARNING",
                "reason": "success_rate below threshold",
                "metric": "success_rate",
                "value": 98.0,
                "threshold": 99.0,
                "source_evidence": "summary.json",
            },
        )
        _, _, body = self.get_metrics()
        samples = parse_metrics(body)
        self.assertEqual(samples["x_superplay_node_status"], "0")
        self.assertEqual(samples["x_superplay_alert_count"], "1")

    def test_output_is_deterministic_and_endpoint_is_read_only(self):
        self.store.write(make_evidence())
        with urlopen(self.base_url + "/metrics", timeout=2) as response:
            first = response.read()
        with urlopen(self.base_url + "/metrics", timeout=2) as response:
            second = response.read()
        self.assertEqual(first, second)
        request = Request(self.base_url + "/metrics", method="POST", data=b"")
        with self.assertRaises(HTTPError) as raised:
            urlopen(request, timeout=2)
        self.assertEqual(raised.exception.code, 405)


if __name__ == "__main__":
    unittest.main()
