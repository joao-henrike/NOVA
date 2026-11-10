#!/usr/bin/env python3
"""Idempotent NOVA monitoring bootstrap. Stdlib only; no AWS keys or extra service."""
from __future__ import annotations

import base64
import hashlib
import json
import os
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


class MonitoringError(RuntimeError):
    pass


def http_json(url: str, method: str = "GET", data=None, auth: str = ""):
    payload = None if data is None else json.dumps(data).encode("utf-8")
    headers = {"Accept": "application/json"}
    if payload is not None:
        headers["Content-Type"] = "application/json"
    if auth:
        headers["Authorization"] = auth
    try:
        with urlopen(Request(url, data=payload, headers=headers, method=method), timeout=8) as r:
            raw = r.read()
            return json.loads(raw.decode("utf-8")) if raw else {}
    except HTTPError as exc:
        if exc.code == 404:
            return None
        raise MonitoringError(f"HTTP {exc.code} from {url.split('?')[0]}") from None
    except (URLError, TimeoutError, ValueError) as exc:
        raise MonitoringError(f"API unavailable at {url.split('?')[0]} ({type(exc).__name__})") from None


def retry(label, operation, attempts=72, delay=5):
    for number in range(attempts):
        try:
            result = operation()
            if result is not None:
                return result
        except MonitoringError:
            if number + 1 == attempts:
                raise
        if number + 1 < attempts:
            time.sleep(delay)
    raise MonitoringError(f"{label} did not become ready")


class Zabbix:
    def __init__(self, url):
        self.url = url
        self.token = ""

    def call(self, method, params=None, token=None):
        headers = f"Bearer {token}" if token else (f"Bearer {self.token}" if self.token else "")
        response = http_json(
            self.url, "POST",
            {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": 1},
            headers,
        )
        if not response or "error" in response:
            error = (response or {}).get("error", {})
            # Never print auth values, request bodies or Zabbix error data.
            raise MonitoringError(f"Zabbix API {method} returned an error ({error.get('code', 'unknown')})")
        return response["result"]

    def login(self, password):
        # Zabbix user.login is an unauthenticated API method. In particular,
        # a password rotation must not reuse the pre-rotation bearer token.
        # That token is still in self.token until authenticate() assigns the
        # freshly issued session, so bypass self.call() for this one method.
        response = http_json(
            self.url, "POST",
            {"jsonrpc": "2.0", "method": "user.login",
             "params": {"username": "Admin", "password": password}, "id": 1},
        )
        if not response or "error" in response or not isinstance(response.get("result"), str):
            error = (response or {}).get("error", {})
            raise MonitoringError(
                f"Zabbix API user.login returned an error ({error.get('code', 'unknown')})"
            )
        return response["result"]

    def authenticate(self, password):
        if not password or len(password) < 12:
            raise MonitoringError("ZABBIX_PASSWORD must contain at least 12 characters")
        try:
            self.token = self.login(password)
            return
        except MonitoringError:
            pass
        # Fresh Zabbix images initially contain Admin/zabbix. Rotate once, then
        # log in with the stable, securely supplied password on all future boots.
        try:
            default_token = self.login("zabbix")
        except MonitoringError as exc:
            raise MonitoringError(
                "Zabbix Admin credentials do not match the configured secret; "
                "recover the correct credential before restarting."
            ) from exc
        self.token = default_token
        users = self.call("user.get", {"filter": {"username": ["Admin"]}, "output": ["userid"]})
        if len(users) != 1:
            raise MonitoringError("Cannot uniquely identify Zabbix Admin")
        self.call("user.update", {
            "userid": users[0]["userid"],
            "current_passwd": "zabbix",
            "passwd": password,
        })
        self.token = self.login(password)
        print("Zabbix: initial Admin password rotated")

    def ensure_health_checks(self, web_url, grafana_health_url):
        groups = self.call("hostgroup.get", {"filter": {"name": ["NOVA Monitoring"]}, "output": ["groupid"]})
        group_id = (groups[0]["groupid"] if groups else self.call(
            "hostgroup.create", {"name": "NOVA Monitoring"}
        )["groupids"][0])
        hosts = self.call("host.get", {"filter": {"host": ["NOVA-Monitoring"]}, "output": ["hostid"]})
        host_id = (hosts[0]["hostid"] if hosts else self.call(
            "host.create",
            {"host": "NOVA-Monitoring", "name": "NOVA Internal Services",
             "groups": [{"groupid": group_id}], "tags": [{"tag": "managed-by", "value": "nova"}]},
        )["hostids"][0])

        scenario = "NOVA internal health"
        existing = self.call("httptest.get", {
            "hostids": [host_id], "filter": {"name": [scenario]}, "output": ["httptestid"]
        })
        steps = [
            {"name": "Zabbix Web", "no": 1, "url": web_url, "status_codes": "200-399"},
            {"name": "Grafana API", "no": 2, "url": grafana_health_url, "status_codes": "200"},
        ]
        payload = {"name": scenario, "hostid": host_id, "delay": "1m", "retries": 2, "steps": steps}
        if existing:
            payload["httptestid"] = existing[0]["httptestid"]
            self.call("httptest.update", payload)
        else:
            self.call("httptest.create", payload)

        description = "NOVA internal HTTP monitoring failed"
        triggers = self.call("trigger.get", {
            "hostids": [host_id], "filter": {"description": [description]}, "output": ["triggerid"]
        })
        if not triggers:
            self.call("trigger.create", {
                "description": description,
                "expression": f"last(/NOVA-Monitoring/web.test.fail[{scenario}])>0",
                "priority": 4,
            })
        print("Zabbix: host, HTTP scenario and failure trigger configured")


def cloudwatch_panel(panel_id, title, namespace, metric, dimensions, y, region, unit="short"):
    return {
        "id": panel_id, "title": title, "type": "timeseries",
        "gridPos": {"h": 8, "w": 12, "x": (panel_id - 1) % 2 * 12, "y": y},
        "datasource": {"type": "cloudwatch", "uid": "nova-cloudwatch"},
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "options": {"legend": {"displayMode": "table", "placement": "bottom"}},
        "targets": [{
            "refId": "A", "queryMode": "Metrics", "metricQueryType": 0,
            "namespace": namespace, "metricName": metric, "dimensions": dimensions,
            "region": region, "statistic": "Average", "period": "300", "matchExact": True,
        }],
    }


def dashboards(cluster, app_db, monitoring_db, region, cloudwatch):
    base = {
        "uid": "nova-monitoring", "title": "NOVA | Monitoring",
        "tags": ["nova", "managed"], "timezone": "browser", "schemaVersion": 39,
        "refresh": "1m", "time": {"from": "now-6h", "to": "now"},
        "annotations": {"list": []}, "editable": True,
        "panels": [
            {"id": 1, "title": "Zabbix HTTP health failures", "type": "timeseries",
             "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
             "datasource": {"type": "alexanderzobnin-zabbix-datasource", "uid": "nova-zabbix"},
             "fieldConfig": {"defaults": {"unit": "short"}, "overrides": []},
             "targets": [{
                 "refId": "A", "mode": 0,
                 "group": {"filter": "NOVA Monitoring"},
                 "host": {"filter": "NOVA-Monitoring"},
                 "application": {"filter": "/.*/"},
                 "item": {"filter": "web.test.fail[NOVA internal health]"},
                 "functions": [], "options": {"showDisabledItems": False},
             }]},
            {"id": 2, "title": "Zabbix HTTP response time", "type": "timeseries",
             "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
             "datasource": {"type": "alexanderzobnin-zabbix-datasource", "uid": "nova-zabbix"},
             "fieldConfig": {"defaults": {"unit": "s"}, "overrides": []},
             "targets": [{
                 "refId": "A", "mode": 0,
                 "group": {"filter": "NOVA Monitoring"},
                 "host": {"filter": "NOVA-Monitoring"},
                 "application": {"filter": "/.*/"},
                 "item": {"filter": "web.test.time[NOVA internal health,.*,resp]"},
                 "functions": [], "options": {"showDisabledItems": False},
             }]},
        ],
    }
    if cloudwatch:
        panels = [
            ("Backend CPU", "AWS/ECS", "CPUUtilization",
             {"ClusterName": cluster, "ServiceName": cluster.replace("-cluster", "-backend")}, "%"),
            ("Backend memory", "AWS/ECS", "MemoryUtilization",
             {"ClusterName": cluster, "ServiceName": cluster.replace("-cluster", "-backend")}, "%"),
            ("Frontend CPU", "AWS/ECS", "CPUUtilization",
             {"ClusterName": cluster, "ServiceName": cluster.replace("-cluster", "-frontend")}, "%"),
            ("Monitoring CPU", "AWS/ECS", "CPUUtilization",
             {"ClusterName": cluster, "ServiceName": cluster.replace("-cluster", "-monitoring")}, "%"),
            ("Application DB connections", "AWS/RDS", "DatabaseConnections",
             {"DBInstanceIdentifier": app_db}, "short"),
            ("Monitoring DB connections", "AWS/RDS", "DatabaseConnections",
             {"DBInstanceIdentifier": monitoring_db}, "short"),
        ]
        for n, (name, namespace, metric, dimensions, unit) in enumerate(panels, start=3):
            base["panels"].append(cloudwatch_panel(
                n, name, namespace, metric, dimensions, (n - 3) // 2 * 8 + 8, region, unit
            ))
    return [base]


class Grafana:
    def __init__(self, url, password):
        if not password:
            raise MonitoringError("GRAFANA_PASSWORD required")
        self.url = url.rstrip("/")
        self.auth = "Basic " + base64.b64encode(
            ("admin:" + password).encode("utf-8")
        ).decode("ascii")

    def call(self, path, method="GET", data=None):
        return http_json(self.url + path, method, data, self.auth)

    def configure(self, zabbix_url, zabbix_password, region, enable_cloudwatch, dashboards_data):
        plugin = "/api/plugins/alexanderzobnin-zabbix-app/settings"
        # The plugin is installed from GF_PLUGINS_PREINSTALL, but app plugins
        # require a separate enable action.
        retry("Zabbix Grafana app", lambda: self.call(plugin, "POST", {"enabled": True}),
              attempts=48, delay=5)
        sources = [{
            "uid": "nova-zabbix", "name": "NOVA Zabbix",
            "type": "alexanderzobnin-zabbix-datasource",
            "url": zabbix_url, "access": "proxy", "isDefault": True,
            "jsonData": {"authType": "userLogin", "username": "Admin",
                         "trends": True, "trendsFrom": "7d", "trendsRange": "4d",
                         "dbConnectionEnable": False},
            "secureJsonData": {"password": zabbix_password},
        }]
        if enable_cloudwatch:
            sources.append({
                "uid": "nova-cloudwatch", "name": "NOVA CloudWatch", "type": "cloudwatch",
                "access": "proxy", "isDefault": False,
                "jsonData": {"authType": "default", "defaultRegion": region},
            })
        for source in sources:
            existing = self.call("/api/datasources/uid/" + source["uid"])
            if existing is None:
                self.call("/api/datasources", "POST", source)
            else:
                self.call("/api/datasources/uid/" + source["uid"], "PUT", source)
        for dashboard in dashboards_data:
            self.call("/api/dashboards/db", "POST",
                      {"dashboard": dashboard, "overwrite": True, "message": "NOVA bootstrap"})
        print(f"Grafana: {len(sources)} data source(s) and {len(dashboards_data)} dashboard(s) configured")


def run():
    grafana_password = os.environ["GRAFANA_PASSWORD"]
    # Distinct password derived from the existing Grafana secret, without
    # provisioning another Secrets Manager secret. A custom ZABBIX_PASSWORD
    # can be supplied for local development or an explicit override.
    zabbix_password = os.getenv("ZABBIX_PASSWORD") or hashlib.sha256(
        ("NOVA-ZABBIX:" + grafana_password).encode("utf-8")
    ).hexdigest()
    if len(zabbix_password) < 12:
        raise MonitoringError("ZABBIX_PASSWORD too short")
    grafana_url = os.environ["GRAFANA_URL"].rstrip("/")
    zabbix_url = os.environ["ZABBIX_URL"]
    region = os.getenv("AWS_REGION", "us-east-1")
    cloudwatch = os.getenv("MONITOR_CLOUDWATCH", "false").lower() == "true"

    zabbix = Zabbix(zabbix_url)
    retry("Zabbix API", lambda: zabbix.call("apiinfo.version"))
    zabbix.authenticate(zabbix_password)
    retry("Grafana HTTP health", lambda: http_json(grafana_url + "/api/health"))
    zabbix.ensure_health_checks(
        os.environ["ZABBIX_WEB_CHECK_URL"], os.environ["GRAFANA_HEALTH_CHECK_URL"]
    )
    grafana = Grafana(grafana_url, grafana_password)
    grafana.configure(zabbix_url, zabbix_password, region, cloudwatch, dashboards(
        os.getenv("NOVA_CLUSTER", "cloudstart-dev-cluster"),
        os.getenv("NOVA_APPLICATION_DB", "cloudstart-dev-db"),
        os.getenv("NOVA_MONITORING_DB", "cloudstart-dev-monitoring-db"),
        region, cloudwatch,
    ))
    print("NOVA monitoring bootstrap complete")


if __name__ == "__main__":
    try:
        run()
    except (MonitoringError, KeyError) as exc:
        print(f"MONITORING BOOTSTRAP FAILED: {exc}", file=sys.stderr)
        sys.exit(1)
