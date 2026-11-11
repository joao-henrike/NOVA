"""Contract tests for the monitoring-only bootstrap; no live API or AWS calls."""
from __future__ import annotations

import unittest
from unittest.mock import patch

from monitoring import bootstrap


class MonitoringTests(unittest.TestCase):
    def test_dashboard_uses_live_zabbix_and_cloudwatch_data_sources(self):
        result = bootstrap.dashboards(
            "cloudstart-dev-cluster", "cloudstart-dev-db",
            "cloudstart-dev-monitoring-db", "us-east-1", True,
        )
        self.assertEqual(len(result), 1)
        dashboard = result[0]
        self.assertEqual(dashboard["uid"], "nova-monitoring")
        self.assertEqual(len(dashboard["panels"]), 8)
        sources = [p["datasource"]["uid"] for p in dashboard["panels"]]
        self.assertEqual(sources[:2], ["nova-zabbix", "nova-zabbix"])
        self.assertEqual(sources[2:], ["nova-cloudwatch"] * 6)
        rds = dashboard["panels"][-1]["targets"][0]
        self.assertEqual(rds["dimensions"]["DBInstanceIdentifier"], "cloudstart-dev-monitoring-db")
        self.assertEqual(rds["namespace"], "AWS/RDS")
        self.assertEqual(result, bootstrap.dashboards(
            "cloudstart-dev-cluster", "cloudstart-dev-db",
            "cloudstart-dev-monitoring-db", "us-east-1", True,
        ))

    def test_local_dashboard_does_not_require_cloudwatch_credentials(self):
        dash = bootstrap.dashboards("c", "a", "b", "us-east-1", False)[0]
        self.assertEqual(len(dash["panels"]), 2)
        self.assertEqual({p["datasource"]["uid"] for p in dash["panels"]}, {"nova-zabbix"})

    def test_zabbix_provision_is_idempotent(self):
        z = bootstrap.Zabbix("http://example.invalid/api")
        calls = []
        state = {"group": False, "host": False, "test": False, "trigger": False}

        def fake_call(method, params=None):
            calls.append((method, params))
            if method == "hostgroup.get":
                return [{"groupid": "5"}] if state["group"] else []
            if method == "hostgroup.create":
                state["group"] = True
                return {"groupids": ["5"]}
            if method == "host.get":
                return [{"hostid": "9"}] if state["host"] else []
            if method == "host.create":
                state["host"] = True
                return {"hostids": ["9"]}
            if method == "httptest.get":
                return ([{"httptestid": "2", "delay": "1m", "retries": "2",
                          "steps": [
                              {"httpstepid": "11", "name": "Zabbix Web", "no": "1",
                               "url": "http://internal-web/", "status_codes": "200-399"},
                              {"httpstepid": "12", "name": "Grafana API", "no": "2",
                               "url": "http://grafana/api/health", "status_codes": "200"},
                          ]}] if state["test"] else [])
            if method == "httptest.create":
                state["test"] = True
                return {"httptestids": ["2"]}
            if method == "httptest.update":
                return {"httptestids": ["2"]}
            if method == "trigger.get":
                return [{"triggerid": "3"}] if state["trigger"] else []
            if method == "trigger.create":
                state["trigger"] = True
                return {"triggerids": ["3"]}
            raise AssertionError(method)

        z.call = fake_call
        for _ in range(2):
            z.ensure_health_checks("http://internal-web/", "http://grafana/api/health")
        methods = [call[0] for call in calls]
        for action in ("hostgroup.create", "host.create", "httptest.create", "trigger.create"):
            self.assertEqual(methods.count(action), 1, action)
        self.assertEqual(methods.count("httptest.update"), 0)
        self.assertEqual(state, {"group": True, "host": True, "test": True, "trigger": True})

    def test_existing_zabbix_web_scenario_updates_without_hostid_and_preserves_step_ids(self):
        z = bootstrap.Zabbix("http://example.invalid/api")
        calls = []

        def fake_call(method, params=None):
            calls.append((method, params))
            if method == "hostgroup.get":
                return [{"groupid": "5"}]
            if method == "host.get":
                return [{"hostid": "9"}]
            if method == "httptest.get":
                return [{"httptestid": "2", "delay": "1m", "retries": "2", "steps": [
                    {"httpstepid": "11", "name": "Zabbix Web", "no": "1",
                     "url": "http://old-internal-web/", "status_codes": "200-399"},
                    {"httpstepid": "12", "name": "Grafana API", "no": "2",
                     "url": "http://grafana/api/health", "status_codes": "200"},
                ]}]
            if method == "httptest.update":
                return {"httptestids": ["2"]}
            if method == "trigger.get":
                return [{"triggerid": "3"}]
            raise AssertionError(method)

        z.call = fake_call
        z.ensure_health_checks("http://internal-web/", "http://grafana/api/health")
        updates = [args for method, args in calls if method == "httptest.update"]
        self.assertEqual(len(updates), 1)
        self.assertNotIn("hostid", updates[0])
        self.assertEqual(updates[0]["httptestid"], "2")
        self.assertEqual([s["httpstepid"] for s in updates[0]["steps"]], ["11", "12"])
        self.assertEqual(updates[0]["steps"][0]["url"], "http://internal-web/")

    def test_existing_zabbix_web_scenario_does_not_replace_unknown_steps(self):
        z = bootstrap.Zabbix("http://example.invalid/api")
        calls = []

        def fake_call(method, params=None):
            calls.append(method)
            if method == "hostgroup.get":
                return [{"groupid": "5"}]
            if method == "host.get":
                return [{"hostid": "9"}]
            if method == "httptest.get":
                return [{"httptestid": "2", "delay": "1m", "retries": "2", "steps": [
                    {"httpstepid": "11", "name": "Unexpected custom step", "no": "1",
                     "url": "http://custom/", "status_codes": "200"}
                ]}]
            raise AssertionError(method)

        z.call = fake_call
        with self.assertRaisesRegex(bootstrap.MonitoringError, "manual review"):
            z.ensure_health_checks("http://internal-web/", "http://grafana/api/health")
        self.assertNotIn("httptest.update", calls)

    def test_zabbix_password_first_boot_is_rotated_once(self):
        z = bootstrap.Zabbix("http://example.invalid/api")
        password = "a-new-strong-password-123"
        attempts = []
        calls = []
        def fake_login(value):
            attempts.append(value)
            if value == password and len(attempts) == 1:
                raise bootstrap.MonitoringError("not initialized")
            return "token"
        def fake_call(method, params=None):
            calls.append((method, params))
            if method == "user.get":
                return [{"userid": "1"}]
            if method == "user.update":
                self.assertEqual(params["current_passwd"], "zabbix")
                self.assertEqual(params["passwd"], password)
                return {"userids": ["1"]}
            raise AssertionError(method)
        z.login = fake_login
        z.call = fake_call
        z.authenticate(password)
        self.assertEqual(attempts, [password, "zabbix", password])
        self.assertEqual([name for name, _ in calls], ["user.get", "user.update"])
        self.assertEqual(z.token, "token")

    def test_zabbix_login_never_reuses_old_authentication_token(self):
        z = bootstrap.Zabbix("http://zabbix.invalid/api_jsonrpc.php")
        z.token = "session-token-before-password-rotation"
        observed = []

        def fake_http_json(url, method="GET", data=None, auth=""):
            observed.append((url, method, data, auth))
            return {"jsonrpc": "2.0", "result": "new-session-token", "id": 1}

        with patch.object(bootstrap, "http_json", side_effect=fake_http_json):
            result = z.login("strong-example-password-not-logged")

        self.assertEqual(result, "new-session-token")
        self.assertEqual(len(observed), 1)
        self.assertEqual(observed[0][3], "")
        self.assertEqual(observed[0][2]["method"], "user.login")
        self.assertEqual(z.token, "session-token-before-password-rotation")

    def test_wrong_zabbix_credentials_fail_without_resetting(self):
        z = bootstrap.Zabbix("http://example.invalid/api")
        with patch.object(z, "login", side_effect=bootstrap.MonitoringError("denied")):
            with self.assertRaisesRegex(bootstrap.MonitoringError, "recover"):
                z.authenticate("valid-length-password-987")

    def test_grafana_sources_create_once_then_update(self):
        grafana = bootstrap.Grafana("http://grafana:3000", "admin-password")
        actions = []
        state = set()
        def fake_call(path, method="GET", data=None):
            actions.append((path, method, data))
            if path.startswith("/api/datasources/uid/") and method == "GET":
                return {"uid": path.split("/")[-1]} if path.split("/")[-1] in state else None
            if path == "/api/datasources" and method == "POST":
                state.add(data["uid"])
            return {"status": "ok"}
        grafana.call = fake_call
        dash = bootstrap.dashboards("cluster", "app", "monitor", "us-east-1", True)
        for _ in range(2):
            grafana.configure("http://zabbix/api", "password-123456", "us-east-1", True, dash)
        self.assertEqual(state, {"nova-zabbix", "nova-cloudwatch"})
        self.assertEqual(len([a for a in actions if a[0] == "/api/datasources" and a[1] == "POST"]), 2)
        self.assertEqual(len([a for a in actions if a[1] == "PUT"]), 2)
        self.assertEqual(len([a for a in actions if a[0] == "/api/dashboards/db"]), 2)

    def test_missing_grafana_password_rejected(self):
        with self.assertRaises(bootstrap.MonitoringError):
            bootstrap.Grafana("http://grafana:3000", "")


if __name__ == "__main__":
    unittest.main()
