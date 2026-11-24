"""Offline collector contract tests. No real AWS or Zabbix calls."""
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from monitoring import collector

ROOT = Path(__file__).resolve().parents[1]


def catalog():
    docs = []
    for f in sorted((ROOT/"grafana"/"dashboards").rglob("*.json")):
        d = json.loads(f.read_text())
        docs.append({"uid": d["uid"], "title": d["title"], "panels": [
            {"title": p["title"], "unit": p["fieldConfig"]["defaults"]["unit"],
             "source": p["datasource"]["uid"], "target": p["targets"][0]}
            for p in d["panels"] if p.get("datasource", {}).get("uid") in ("nova-cloudwatch", "nova-zabbix")]})
    return docs


class CollectorTests(unittest.TestCase):
    def test_catalog(self):
        docs = catalog()
        self.assertEqual(len(docs), 30)
        self.assertEqual(sum(len(d["panels"]) for d in docs), 617)
        specs, items, live = collector.inventory(docs, {"project": "demo", "cluster": "demo-cluster"})
        self.assertLess(len(specs), 458)
        self.assertGreater(len(specs), 0)
        self.assertTrue(all(len("zbx-"+d[0]) <= 40 for d in live))
        self.assertTrue(collector.IMPLEMENTED <= {k for _, k in items})
        for d in live:
            dashboard = collector.live_dashboard(d, collector.IMPLEMENTED)
            self.assertTrue(all(p.get("datasource", {}).get("uid") == "nova-zabbix" for p in dashboard["panels"][1:]))
            self.assertTrue(any(p.get("type") == "timeseries" for p in dashboard["panels"]))
        self.assertIsNone(collector.resolve("$nat_a", {}))
        self.assertEqual(collector.resolve("${project}-frontend", {"project": "demo"}), "demo-frontend")

    def test_restore_cursors_preserves_newer_acknowledged_values(self):
        class FakeZabbix:
            def call(self, method, params):
                if method == "host.get":
                    return [{"hostid": "1"}]
                if method == "item.get":
                    return [{"itemid": "11", "key_": "old", "lastclock": "100"},
                            {"itemid": "12", "key_": "new", "lastclock": "150"},
                            {"itemid": "13", "key_": "unmanaged", "lastclock": "999"}]
                raise AssertionError(method)
        items = {("host", "old"): ("Old", ""), ("host", "new"): ("New", "")}
        last = {("host", "new"): 200}
        collector.restore_cursors(FakeZabbix(), items, last)
        self.assertEqual(last, {("host", "old"): 100, ("host", "new"): 200})

    def test_metric_identity_stable(self):
        a = {"namespace": "AWS/ECS", "metricName": "CPUUtilization", "dimensions": {"a": "b", "c": "d"},
             "statistic": "Average", "period": "300"}
        b = {**a, "dimensions": {"c": "d", "a": "b"}}
        self.assertEqual(collector.metric_identity(a), collector.metric_identity(b))

    def test_missing_data_is_not_zero(self):
        self.assertIsNone(collector.row("host", "item", None, 1))
        self.assertIsNone(collector.row("host", "item", float("nan"), 1))
        self.assertEqual(collector.row("host", "item", 0, 1)["value"], "0.0")

    def test_metric_data_parsing(self):
        import xml.etree.ElementTree as ET
        import datetime as dt
        aws = collector.AWS("us-east-1")
        spec = {"namespace": "AWS/ECS", "metricName": "CPUUtilization", "dimensions": {"ServiceName": "a"},
                "statistic": "Average", "period": "300"}
        xml = ET.fromstring("""<GetMetricDataResponse><GetMetricDataResult><MetricDataResults>
          <member><Id>m1</Id><StatusCode>Complete</StatusCode><Timestamps><member>2026-01-01T00:00:00Z</member></Timestamps><Values><member>13.5</member></Values></member>
          <member><Id>m2</Id><StatusCode>PartialData</StatusCode><Timestamps><member>2026-01-01T00:00:00Z</member></Timestamps><Values><member>0</member></Values></member>
        </MetricDataResults></GetMetricDataResult></GetMetricDataResponse>""")
        with patch.object(aws, "query", return_value=xml) as query:
            result = aws.metric_data({"a": spec, "b": spec, "c": {**spec, "dimensions": {"ServiceName": None}}}, dt.datetime(2026,1,1,0,15,tzinfo=dt.timezone.utc))
        self.assertEqual(list(result), ["a"])
        self.assertEqual(list(result["a"].values()), [13.5])
        self.assertEqual(query.call_args.args[1], "GetMetricData")
        self.assertNotIn("MetricDataQueries.member.3.Id", query.call_args.args[3])


if __name__ == "__main__":
    unittest.main()
