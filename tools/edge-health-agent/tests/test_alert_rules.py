import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))

from alert.rules import SummaryError, evaluate_summary, evaluate_summary_file, write_alert


def summary(success_rate=100.0, p95_latency=100.0, tcp_failures=0):
    return {
        "generated_at": "2026-09-08T12:00:00.000Z",
        "total_checks": 10,
        "success_count": 10,
        "failure_count": 0,
        "success_rate": success_rate,
        "tcp_failures": tcp_failures,
        "http_failures": 0,
        "average_latency": 50.0,
        "p95_latency": p95_latency,
    }


class AlertRuleTests(unittest.TestCase):
    def test_healthy_state_has_no_alert(self):
        alert = evaluate_summary(summary())
        self.assertEqual(alert["level"], "NONE")
        self.assertEqual(alert["metric"], "")
        self.assertIsNone(alert["value"])
        self.assertEqual(alert["reason"], "no alert rule fired")

    def test_success_rate_warning(self):
        alert = evaluate_summary(summary(success_rate=98.5))
        self.assertEqual(alert["level"], "WARNING")
        self.assertEqual(alert["metric"], "success_rate")
        self.assertEqual(alert["value"], 98.5)
        self.assertEqual(alert["threshold"], 99.0)

    def test_latency_warning(self):
        alert = evaluate_summary(summary(p95_latency=3000.1))
        self.assertEqual(alert["level"], "WARNING")
        self.assertEqual(alert["metric"], "p95_latency")
        self.assertEqual(alert["threshold"], 3000.0)

    def test_tcp_failure_critical_takes_precedence(self):
        alert = evaluate_summary(summary(success_rate=50.0, p95_latency=9000, tcp_failures=4))
        self.assertEqual(alert["level"], "CRITICAL")
        self.assertEqual(alert["metric"], "tcp_failures")
        self.assertEqual(alert["value"], 4.0)
        self.assertEqual(alert["threshold"], 3.0)

    def test_custom_thresholds_are_applied(self):
        alert = evaluate_summary(
            summary(success_rate=97.0, p95_latency=2500, tcp_failures=2),
            thresholds={
                "success_rate_threshold": 98,
                "p95_latency_threshold_ms": 2000,
                "tcp_failure_threshold": 5,
            },
        )
        self.assertEqual(alert["level"], "WARNING")
        self.assertEqual(alert["metric"], "success_rate")
        self.assertEqual(alert["threshold"], 98.0)

    def test_invalid_summary_is_rejected(self):
        with self.assertRaises(SummaryError):
            evaluate_summary({"generated_at": "2026-09-08T12:00:00Z"})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "summary.json"
            path.write_text("{not-json", encoding="utf-8")
            with self.assertRaises(SummaryError):
                evaluate_summary_file(path)

    def test_alert_output_is_reproducible_and_schema_validated(self):
        alert = evaluate_summary(summary(), source_evidence="evidence/summary.json")
        with tempfile.TemporaryDirectory() as directory:
            first = write_alert(Path(directory) / "first.json", alert)
            second = write_alert(Path(directory) / "second.json", alert)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(json.loads(first.read_text(encoding="utf-8")), alert)


if __name__ == "__main__":
    unittest.main()
