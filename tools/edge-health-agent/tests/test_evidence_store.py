import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))

from evidence.store import EvidenceStore


def evidence(timestamp, tcp_success=True, http_success=True, tcp_latency=10, http_latency=20):
    return {
        "schema_version": "p12.health-probe.v1",
        "timestamp": timestamp,
        "tcp": {
            "host": "edge.example",
            "port": 443,
            "success": tcp_success,
            "latency_ms": tcp_latency,
            "error": None if tcp_success else "CONNECT_TIMEOUT",
        },
        "http": {
            "gstatic": {
                "name": "gstatic",
                "url": "https://gstatic.example/204",
                "expected_status": [204],
                "status": 204 if http_success else 500,
                "success": http_success,
                "latency_ms": http_latency,
                "error": None if http_success else "HTTP_STATUS_500",
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
        "health_score": 100.0 if tcp_success and http_success else 0.0,
    }


class EvidenceStoreTests(unittest.TestCase):
    def test_evidence_file_creation_is_timestamped_and_reproducible(self):
        with tempfile.TemporaryDirectory() as directory:
            store = EvidenceStore(directory)
            result = store.write(evidence("2026-09-08T12:00:00.000Z"))
            self.assertEqual(result.name, "probe-20260908T120000.json")
            self.assertEqual(result.parent.name, "2026-09-08")
            self.assertEqual(
                json.loads(result.read_text(encoding="utf-8"))["timestamp"],
                "2026-09-08T12:00:00.000Z",
            )

    def test_summary_calculates_counts_rates_and_percentile(self):
        with tempfile.TemporaryDirectory() as directory:
            store = EvidenceStore(directory)
            store.write(evidence("2026-09-08T12:00:00.000Z", True, True, 10, 20))
            store.write(evidence("2026-09-08T12:01:00.000Z", True, False, 20, 40))
            store.write(evidence("2026-09-08T12:02:00.000Z", False, True, 30, 60))
            summary = store.write_summary()
            payload = json.loads(summary.read_text(encoding="utf-8"))
            self.assertEqual(payload["total_checks"], 3)
            self.assertEqual(payload["success_count"], 1)
            self.assertEqual(payload["failure_count"], 2)
            self.assertEqual(payload["success_rate"], 33.33)
            self.assertEqual(payload["tcp_failures"], 1)
            self.assertEqual(payload["http_failures"], 1)
            self.assertEqual(payload["average_latency"], 30.0)
            self.assertEqual(payload["p95_latency"], 60.0)

    def test_retention_cleanup_removes_only_old_probe_files(self):
        with tempfile.TemporaryDirectory() as directory:
            store = EvidenceStore(directory, max_days=7)
            old_path = store.write(evidence("2026-08-01T12:00:00.000Z"))
            fresh_path = store.write(evidence("2026-09-08T12:00:00.000Z"))
            now = datetime(2026, 9, 8, 12, 0, tzinfo=timezone.utc)
            old_mtime = (now - timedelta(days=8)).timestamp()
            fresh_mtime = (now - timedelta(days=1)).timestamp()
            os.utime(old_path, (old_mtime, old_mtime))
            os.utime(fresh_path, (fresh_mtime, fresh_mtime))
            removed = store.cleanup(now=now)
            self.assertEqual(removed, [old_path])
            self.assertFalse(old_path.exists())
            self.assertTrue(fresh_path.exists())

    def test_corrupted_evidence_is_skipped_and_counted(self):
        with tempfile.TemporaryDirectory() as directory:
            store = EvidenceStore(directory)
            valid = store.write(evidence("2026-09-08T12:00:00.000Z"))
            corrupted = valid.parent / "probe-20260908T120001.json"
            corrupted.write_text('{"not": "evidence"', encoding="utf-8")
            invalid = valid.parent / "probe-20260908T120002.json"
            invalid.write_text(json.dumps({"not": "the probe schema"}), encoding="utf-8")
            payload = store.summarize()
            self.assertEqual(payload["total_checks"], 1)
            self.assertEqual(payload["success_count"], 1)
            self.assertEqual(payload["corrupted_evidence_count"], 2)


if __name__ == "__main__":
    unittest.main()
