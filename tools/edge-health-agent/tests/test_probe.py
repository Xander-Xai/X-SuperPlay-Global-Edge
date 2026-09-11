import io
import json
import socket
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.error import URLError

sys.path.insert(0, str(Path(__file__).parents[1]))

import probe


class FakeResponse:
    def __init__(self, status=200, body=b"ok"):
        self.status = status
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def getcode(self):
        return self.status

    def read(self, _limit=-1):
        return self.body


class FakeOpener:
    def __init__(self, response=None, error=None):
        self.response = response
        self.error = error
        self.requests = []

    def open(self, request, timeout):
        self.requests.append((request, timeout))
        if self.error:
            raise self.error
        return self.response


def base_config():
    return {
        "timeout_seconds": 1.0,
        "tcp": {"host": "edge.example", "port": 443},
        "http": {
            "targets": [
                {"name": "gstatic", "url": "https://gstatic.example/204", "expected_status": [204]}
            ]
        },
        "egress": {
            "enabled": False,
            "url": "https://ip.example/",
            "expected_ip": "",
            "proxy": "",
        },
    }


class ProbeTests(unittest.TestCase):
    def test_tcp_success_records_latency_and_closes_socket(self):
        connection = Mock()
        connection.__enter__ = Mock(return_value=connection)
        connection.__exit__ = Mock(return_value=False)
        with patch.object(probe.socket, "create_connection", return_value=connection) as create:
            result = probe.probe_tcp("edge.example", 443, 1.0)
        self.assertTrue(result["success"])
        self.assertIsInstance(result["latency_ms"], float)
        self.assertIsNone(result["error"])
        create.assert_called_once_with(("edge.example", 443), timeout=1.0)

    def test_tcp_timeout_is_classified_without_raising(self):
        with patch.object(probe.socket, "create_connection", side_effect=socket.timeout("slow")):
            result = probe.probe_tcp("edge.example", 443, 0.01)
        self.assertFalse(result["success"])
        self.assertIn("CONNECT_TIMEOUT", result["error"])
        self.assertGreaterEqual(result["latency_ms"], 0)

    def test_http_status_failure_is_evidence(self):
        opener = FakeOpener(response=FakeResponse(status=500, body=b"error"))
        target = {"name": "github", "url": "https://github.example/", "expected_status": [200]}
        result = probe.probe_http_target(target, 1.0, opener=opener)
        self.assertEqual(result["status"], 500)
        self.assertFalse(result["success"])
        self.assertEqual(result["error"], "HTTP_STATUS_500")
        self.assertEqual(len(opener.requests), 1)

    def test_http_network_failure_is_mocked(self):
        opener = FakeOpener(error=URLError("offline"))
        target = {"name": "google", "url": "https://google.example/", "expected_status": [204]}
        result = probe.probe_http_target(target, 1.0, opener=opener)
        self.assertIsNone(result["status"])
        self.assertFalse(result["success"])
        self.assertIn("offline", result["error"])

    def test_egress_proxy_comparison(self):
        opener = FakeOpener(response=FakeResponse(body=b'{"ip":"203.0.113.7"}'))
        config = {
            "enabled": True,
            "url": "https://ip.example/",
            "expected_ip": "203.0.113.7",
            "proxy": "http://127.0.0.1:7890",
        }
        result = probe.probe_egress(config, 1.0, opener=opener)
        self.assertTrue(result["success"])
        self.assertTrue(result["match"])
        self.assertEqual(result["observed_ip"], "203.0.113.7")
        self.assertTrue(result["proxy_configured"])

    def test_egress_failure_is_recorded(self):
        opener = FakeOpener(error=URLError("proxy refused"))
        config = {
            "enabled": True,
            "url": "https://ip.example/",
            "expected_ip": "203.0.113.7",
            "proxy": "http://127.0.0.1:7890",
        }
        result = probe.probe_egress(config, 1.0, opener=opener)
        self.assertFalse(result["success"])
        self.assertIn("proxy refused", result["error"])

    def test_health_score_excludes_disabled_egress(self):
        tcp = {"success": True}
        http = {"gstatic": {"success": True}, "github": {"success": False}}
        egress = {"enabled": False, "success": False}
        self.assertEqual(probe.calculate_health_score(tcp, http, egress), 75.0)

    def test_run_probe_output_validates_against_json_schema(self):
        tcp_connection = Mock()
        tcp_connection.__enter__ = Mock(return_value=tcp_connection)
        tcp_connection.__exit__ = Mock(return_value=False)
        config = base_config()
        with patch.object(probe.socket, "create_connection", return_value=tcp_connection), patch.object(
            probe, "make_opener", return_value=FakeOpener(response=FakeResponse(status=204))
        ):
            evidence = probe.run_probe(config)
        probe.validate_evidence(evidence)
        self.assertEqual(evidence["schema_version"], probe.SCHEMA_VERSION)
        self.assertIn("timestamp", evidence)
        self.assertIn("tcp", evidence)
        self.assertIn("http", evidence)
        self.assertIn("egress", evidence)
        self.assertEqual(evidence["health_score"], 100.0)
        json.dumps(evidence)

    def test_example_config_loads_without_network(self):
        config_path = Path(__file__).parents[1] / "config.example.yaml"
        config = probe.load_config(config_path)
        self.assertEqual(config["tcp"]["port"], 443)
        self.assertEqual(len(config["http"]["targets"]), 3)

    def test_output_evidence_cli_writes_probe_and_summary(self):
        config = base_config()
        with tempfile.TemporaryDirectory() as directory:
            config["evidence"] = {"root": directory, "max_days": 7}
            tcp_connection = Mock()
            tcp_connection.__enter__ = Mock(return_value=tcp_connection)
            tcp_connection.__exit__ = Mock(return_value=False)
            with patch.object(probe.socket, "create_connection", return_value=tcp_connection), patch.object(
                probe, "make_opener", return_value=FakeOpener(response=FakeResponse(status=204))
            ):
                generated = probe.run_probe(config)
            stdout = io.StringIO()
            stderr = io.StringIO()
            with patch.object(probe, "load_config", return_value=config), patch.object(
                probe, "run_probe", return_value=generated
            ), redirect_stdout(stdout), redirect_stderr(stderr):
                result = probe.main(["--config", "ignored.yaml", "--output-evidence"])
            self.assertEqual(result, 0)
            self.assertTrue(list(Path(directory).glob("*/probe-*.json")))
            self.assertTrue((Path(directory) / "summary.json").exists())
            self.assertIn("evidence_path=", stderr.getvalue())
            self.assertEqual(json.loads(stdout.getvalue())["schema_version"], probe.SCHEMA_VERSION)

    def test_evaluate_alert_cli_reads_summary_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary_path = root / "summary.json"
            alert_path = root / "alert.json"
            summary_path.write_text(
                json.dumps(
                    {
                        "generated_at": "2026-09-08T12:00:00.000Z",
                        "success_rate": 98.0,
                        "p95_latency": 100.0,
                        "tcp_failures": 0,
                    }
                ),
                encoding="utf-8",
            )
            config = base_config()
            config["evidence"] = {"root": directory, "max_days": 7}
            config["alerts"] = {
                "summary_path": str(summary_path),
                "output_path": str(alert_path),
                "success_rate_threshold": 99.0,
                "p95_latency_threshold_ms": 3000.0,
                "tcp_failure_threshold": 3,
            }
            stdout = io.StringIO()
            stderr = io.StringIO()
            with patch.object(probe, "load_config", return_value=config), redirect_stdout(stdout), redirect_stderr(stderr):
                result = probe.main(["--evaluate-alert"])
            self.assertEqual(result, 0)
            self.assertEqual(json.loads(stdout.getvalue())["level"], "WARNING")
            self.assertEqual(json.loads(alert_path.read_text(encoding="utf-8"))["metric"], "success_rate")
            self.assertIn("alert_path=", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
