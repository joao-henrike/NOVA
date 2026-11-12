"""Offline unit tests for safety properties and pure checks in resilience suite."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "run.py"
spec = importlib.util.spec_from_file_location("nova_resilience_run", MODULE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class GuardTests(unittest.TestCase):
    def setUp(self):
        mod.EVENTS.clear()
        mod.FAILS = 0
        mod.WARNINGS = 0

    def test_wrong_account_fails_closed(self):
        with patch.object(mod, "aws", return_value={"Account": "000000000000"}):
            with self.assertRaisesRegex(RuntimeError, "Wrong AWS account"):
                mod.guarded_identity()

    def test_account_accepts_only_project_account(self):
        with patch.object(mod, "aws", return_value={"Account": mod.ACCOUNT}):
            mod.guarded_identity()
        self.assertEqual(mod.EVENTS[-1]["kind"], "PASS")

    def test_monitoring_cannot_be_fault_injected(self):
        with self.assertRaisesRegex(RuntimeError, "Only frontend/backend"):
            mod.task_recovery("monitoring", "STOP ONE MONITORING TASK")

    def test_confirmation_is_checked_before_mutation(self):
        with patch.object(mod, "aws") as spy:
            with self.assertRaisesRegex(RuntimeError, "Missing exact confirmation"):
                mod.task_recovery("frontend", "")
            spy.assert_not_called()

    def test_record_counts_failure_and_warning(self):
        mod.record("PASS", "ok")
        mod.record("WARN", "caveat")
        mod.record("FAIL", "broken")
        self.assertEqual((mod.FAILS, mod.WARNINGS), (1, 1))

    def test_expected_target_group_names(self):
        self.assertEqual(mod.TARGET_GROUPS["frontend"], "cloudstart-dev-frontend-tg")
        self.assertEqual(mod.TARGET_GROUPS["monitoring"], "cloudstart-dev-grafana-tg")

    def test_http_paths_are_get_only(self):
        self.assertEqual(mod.PATHS, (
            "/", "/health", "/api/health", "/api/health/db", "/grafana/api/health"
        ))


if __name__ == "__main__":
    unittest.main()
