#!/usr/bin/env python3
"""NOVA continuous Zabbix collector; only read APIs, no AWS access keys in config."""
from __future__ import annotations

import base64
import datetime as dt
import gzip
import hashlib
import hmac
import ipaddress
import json
import math
import os
import re
import socket
import struct
import time
import xml.etree.ElementTree as ET
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from urllib.error import HTTPError

try:
    from . import bootstrap
except ImportError:
    import bootstrap

GROUP = "NOVA Extended"
AWS_HOST = "NOVA-AWS"
CONTROL = "NOVA-Collector"
DS = {"type": "alexanderzobnin-zabbix-datasource", "uid": "nova-zabbix"}
# Only these contracts have an implemented collector. Never publish zero for
# a missing source, unavailable measurement or an unimplemented contract.
IMPLEMENTED = {
    "nova.d01.active_incidents", "nova.d01.last_collection_age",
    "nova.d06.external_http_status", "nova.d06.external_http_latency_seconds",
    "nova.d07.registered_targets", "nova.d07.draining_targets",
    "nova.d08.subnet_free_ips", "nova.d08.subnet_ip_utilization_pct",
    "nova.d08.blackhole_routes", "nova.d09.nat_available",
    "nova.d09.nat_packet_drop_pct",
    "nova.d10.frontend_http_status", "nova.d10.frontend_ttfb_seconds",
    "nova.d13.db_available", "nova.d13.db_backup_age_seconds",
    "nova.d13.db_latest_restorable_age_seconds",
    "nova.d14.db_available", "nova.d14.db_backup_age_seconds",
    "nova.d14.db_latest_restorable_age_seconds",
    "nova.d17.zabbix_unsupported_items",
    "nova.d21.app_backup_age_seconds", "nova.d21.monitoring_backup_age_seconds",
    "nova.d21.snapshot_count", "nova.d26.image_count",
    "nova.d26.image_bytes", "nova.d26.untagged_images",
}
UNIT = {"percent": "%", "s": "s", "bytes": "B", "Bps": "Bps", "decmbytes": "MB",
        "iops": "iops", "pps": "pps", "currencyUSD": "USD"}
UTC = dt.timezone.utc


def decode_catalog(value):
    return json.loads(gzip.decompress(base64.b64decode(value)))


def utc(value=None):
    return value or dt.datetime.now(UTC)


def stamp(value):
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_date(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def number(value):
    try:
        n = float(value)
        return n if math.isfinite(n) else None
    except (TypeError, ValueError, OverflowError):
        return None


def metric_identity(target):
    spec = {k: target[k] for k in ("namespace", "metricName", "dimensions", "statistic", "period")}
    key = hashlib.sha256(json.dumps(spec, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:24]
    return "nova.cw." + key, spec


def resolve(value, variables):
    def repl(match):
        name = match.group(1) or match.group(2)
        return str(variables.get(name) or "")
    s = re.sub(r"\$\{([a-z_]+)\}|\$([a-z_]+)", repl, value)
    return None if not s or "REPLACE_WITH" in s or s.startswith("-") else s


def inventory(catalog, variables):
    specs, items, docs = {}, {}, []
    for doc in catalog:
        panels = []
        for p in doc["panels"]:
            t, unit, title = p["target"], p["unit"], p["title"]
            if p["source"] == "nova-cloudwatch":
                key, raw = metric_identity(t)
                name = raw["metricName"] + " [" + key.rsplit(".", 1)[-1] + "]"
                dims = {k: resolve(v, variables) for k, v in raw["dimensions"].items()}
                spec = {**raw, "dimensions": dims}
                specs[key] = spec
                items[(AWS_HOST, key)] = (name, unit)
                target = ztarget(GROUP, AWS_HOST, name)
                if any(v is None for v in dims.values()):
                    title = "SEM RECURSO | " + title
            elif t.get("group", {}).get("filter") == GROUP:
                host = t["host"]["filter"]
                name = t["item"]["filter"]
                match = re.fullmatch(r"NOVA (\d\d) ([a-z0-9_]+)", name)
                if not match:
                    raise ValueError("Unexpected NOVA contract item")
                key = "nova.d" + match[1] + "." + match[2]
                items[(host, key)] = (name, unit)
                target = ztarget(GROUP, host, name)
                title = title.removeprefix("PENDENTE | ")
                if key == "nova.d21.snapshot_count":
                    title += " (automated RDS snapshots only)"
                if key == "nova.d08.subnet_free_ips":
                    title += " (VPC total)"
                if key == "nova.d01.last_collection_age":
                    title += " (previous successful cycle)"
                if key not in IMPLEMENTED:
                    title = "PENDENTE | " + title
                elif key in HTTPS_ONLY:
                    title = "HTTPS necessário | " + title
            else:
                target = t
            panels.append((title, unit, target))
        docs.append((doc["uid"], doc["title"], panels))
    for key, unit in (("heartbeat", "short"), ("cycle.ok", "short"),
                      ("cloudwatch.series.available", "short"),
                      ("cloudwatch.series.expected", "short"),
                      ("source.errors", "short")):
        items[(CONTROL, "nova.collector." + key)] = ("NOVA collector " + key, unit)
    return specs, items, docs


HTTPS_ONLY = {"nova.d06.external_http_status", "nova.d06.external_http_latency_seconds",
              "nova.d10.frontend_http_status", "nova.d10.frontend_ttfb_seconds"}


def ztarget(group, host, item):
    return {"refId": "A", "mode": 0, "group": {"filter": group},
            "host": {"filter": host}, "item": {"filter": item},
            "functions": [], "options": {"showDisabledItems": False}}


class AWS:
    """AWS Query/JSON protocols using temporary credentials of this ECS task."""
    def __init__(self, region):
        if not re.fullmatch(r"[a-z]{2}(?:-[a-z0-9]+)+-\d+", region):
            raise ValueError("Invalid region")
        self.region = region
        self.creds = None

    def credentials(self):
        if self.creds is None or parse_date(self.creds["Expiration"]) <= utc() + dt.timedelta(minutes=5):
            relative = os.environ.get("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "")
            if not re.fullmatch(r"/v2/credentials/[a-zA-Z0-9-]+", relative):
                raise RuntimeError("ECS task credentials not available")
            with urlopen("http://169.254.170.2" + relative, timeout=5) as response:
                self.creds = json.load(response)
        return self.creds

    def post(self, service, body, content_type, target=None):
        credentials = self.credentials()
        host = ("api.ecr" if service == "ecr" else service) + "." + self.region + ".amazonaws.com"
        now = utc()
        date, timestamp = now.strftime("%Y%m%d"), now.strftime("%Y%m%dT%H%M%SZ")
        headers = {"content-type": content_type, "host": host, "x-amz-date": timestamp,
                   "x-amz-security-token": credentials["Token"]}
        if target:
            headers["x-amz-target"] = target
        signed = ";".join(sorted(headers))
        canonical_headers = "".join(k + ":" + headers[k] + "\n" for k in sorted(headers))
        digest = lambda x: hashlib.sha256(x).hexdigest()
        request = "\n".join(("POST", "/", "", canonical_headers, signed, digest(body)))
        scope = "/".join((date, self.region, service, "aws4_request"))
        string_to_sign = "\n".join(("AWS4-HMAC-SHA256", timestamp, scope, digest(request.encode())))
        signing_key = ("AWS4" + credentials["SecretAccessKey"]).encode()
        for part in (date, self.region, service, "aws4_request"):
            signing_key = hmac.new(signing_key, part.encode(), hashlib.sha256).digest()
        signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()
        headers["Authorization"] = ("AWS4-HMAC-SHA256 Credential=" + credentials["AccessKeyId"]
                                    + "/" + scope + ", SignedHeaders=" + signed + ", Signature=" + signature)
        with urlopen(Request("https://" + host + "/", data=body, headers=headers, method="POST"), timeout=25) as response:
            return response.read()

    def dashboard_bundle(self, bucket, expected_hash):
        """Read only the private Terraform-managed object using ECS task credentials."""
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", bucket):
            raise ValueError("Invalid dashboard bucket")
        credentials = self.credentials()
        host = bucket + ".s3." + self.region + ".amazonaws.com"
        path = "/dashboards.json"
        now = utc()
        date, timestamp = now.strftime("%Y%m%d"), now.strftime("%Y%m%dT%H%M%SZ")
        digest = lambda data: hashlib.sha256(data).hexdigest()
        headers = {"host": host, "x-amz-date": timestamp,
                   "x-amz-content-sha256": digest(b""), "x-amz-security-token": credentials["Token"]}
        signed = ";".join(sorted(headers))
        canonical = "".join(k + ":" + headers[k] + "\n" for k in sorted(headers))
        request = "\n".join(("GET", path, "", canonical, signed, digest(b"")))
        scope = "/".join((date, self.region, "s3", "aws4_request"))
        to_sign = "\n".join(("AWS4-HMAC-SHA256", timestamp, scope, digest(request.encode())))
        key = ("AWS4" + credentials["SecretAccessKey"]).encode()
        for part in (date, self.region, "s3", "aws4_request"):
            key = hmac.new(key, part.encode(), hashlib.sha256).digest()
        signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
        headers["Authorization"] = ("AWS4-HMAC-SHA256 Credential=" + credentials["AccessKeyId"]
                                    + "/" + scope + ", SignedHeaders=" + signed + ", Signature=" + signature)
        with urlopen(Request("https://" + host + path, headers=headers, method="GET"), timeout=30) as response:
            raw = response.read(10_000_001)
        if len(raw) > 10_000_000 or digest(raw) != expected_hash:
            raise RuntimeError("Dashboard bundle integrity check failed")
        docs = json.loads(raw)
        if len(docs) != 30 or len({d["uid"] for d in docs}) != 30:
            raise RuntimeError("Dashboard bundle must contain 30 unique dashboards")
        return docs

    def query(self, service, action, version, params):
        body = urlencode({"Action": action, "Version": version, **params}).encode()
        root = ET.fromstring(self.post(service, body, "application/x-www-form-urlencoded; charset=utf-8"))
        for node in root.iter():
            node.tag = node.tag.split("}")[-1]
        return root

    def json_api(self, service, target, params):
        return json.loads(self.post(service, json.dumps(params).encode(), "application/x-amz-json-1.1", target))

    def metric_data(self, specs, now):
        """Return timestamped samples; missing, partial and nonnumeric values are omitted."""
        eligible = [(k, s) for k, s in sorted(specs.items()) if all(s["dimensions"].values())]
        # Query 45 minutes, excluding the current incomplete five-minute bin.
        end = now.replace(second=0, microsecond=0) - dt.timedelta(minutes=now.minute % 5)
        start = end - dt.timedelta(minutes=45)
        result = {}
        for j in range(0, len(eligible), 100):
            batch = eligible[j:j+100]
            params = {"StartTime": stamp(start), "EndTime": stamp(end), "ScanBy": "TimestampAscending"}
            ids = {}
            for i, (key, s) in enumerate(batch, 1):
                ident = "m" + str(i)
                ids[ident] = key
                p = "MetricDataQueries.member." + str(i) + "."
                m = p + "MetricStat."
                params.update({p+"Id": ident, p+"ReturnData": "true", m+"Metric.Namespace": s["namespace"],
                               m+"Metric.MetricName": s["metricName"], m+"Period": s["period"],
                               m+"Stat": s["statistic"]})
                for k, (name, value) in enumerate(sorted(s["dimensions"].items()), 1):
                    d = m + "Metric.Dimensions.member." + str(k) + "."
                    params[d+"Name"], params[d+"Value"] = name, value
            for _ in range(20):
                root = self.query("monitoring", "GetMetricData", "2010-08-01", params)
                for row in root.findall(".//MetricDataResults/member"):
                    ident, status = row.findtext("Id"), row.findtext("StatusCode")
                    if ident not in ids or status != "Complete":
                        continue
                    times = row.findall("Timestamps/member")
                    vals = row.findall("Values/member")
                    if len(times) != len(vals):
                        continue
                    for t, v in zip(times, vals):
                        n = number(v.text)
                        if n is not None and t.text:
                            ts = int(parse_date(t.text).timestamp())
                            result.setdefault(ids[ident], {})[ts] = n
                token = root.findtext(".//NextToken")
                if not token:
                    break
                params["NextToken"] = token
            else:
                raise RuntimeError("CloudWatch pagination limit")
        return result


def ensure_group(z):
    found = z.call("hostgroup.get", {"filter": {"name": [GROUP]}, "output": ["groupid"]})
    return found[0]["groupid"] if found else z.call("hostgroup.create", {"name": GROUP})["groupids"][0]


def ensure_host(z, group_id, host):
    found = z.call("host.get", {"filter": {"host": [host]}, "output": ["hostid", "name"]})
    if found:
        if len(found) != 1:
            raise ValueError("Ambiguous host")
        return found[0]["hostid"]
    return z.call("host.create", {"host": host, "name": host, "groups": [{"groupid": group_id}],
                                  "tags": [{"tag": "managed-by", "value": "nova"}]})["hostids"][0]


def ensure_items(z, items):
    group_id = ensure_group(z)
    for host in sorted({h for h, _ in items}):
        host_id = ensure_host(z, group_id, host)
        existing = {x["key_"]: x for x in z.call("item.get", {
            "hostids": [host_id], "output": ["itemid", "key_", "type", "value_type", "name"]})}
        creates = []
        for (h, key), (name, unit) in items.items():
            if h != host:
                continue
            if key in existing:
                old = existing[key]
                if str(old["type"]) != "2" or str(old["value_type"]) != "0" or old["name"] != name:
                    raise ValueError("Existing item requires manual review: " + key)
                continue
            creates.append({"hostid": host_id, "name": name, "key_": key, "type": 2,
                            "value_type": 0, "delay": "0", "history": "7d", "trends": "90d",
                            "units": UNIT.get(unit, ""), "trapper_hosts": "127.0.0.1",
                            "description": "NOVA managed collector; no synthetic values",
                            "tags": [{"tag": "managed-by", "value": "nova"}]})
        for i in range(0, len(creates), 100):
            z.call("item.create", creates[i:i+100])
    return group_id


def restore_cursors(z, items, last):
    """Recover committed history from Zabbix's persistent DB via its API.

    Never reset an in-process watermark. All NOVA collector items use history=0
    (numeric float). Reconcile only items which belong to this collector.
    """
    for host in sorted({h for h, _ in items}):
        found = z.call("host.get", {"filter": {"host": [host]}, "output": ["hostid"]})
        if len(found) != 1:
            raise RuntimeError("NOVA cursor host missing or ambiguous")
        existing = z.call("item.get", {
            "hostids": [found[0]["hostid"]],
            "output": ["itemid", "key_", "lastclock"],
        })
        for item in existing:
            pair = (host, item["key_"])
            if pair in items:
                clock = int(item.get("lastclock") or 0)
                last[pair] = max(last.get(pair, 0), clock)


def ensure_triggers(z, interval):
    host = CONTROL
    checks = [
        ("NOVA collector heartbeat missing", "nodata(/"+host+"/nova.collector.heartbeat,"+str(interval*3)+"s)=1", 4),
        ("NOVA collector source failure", "last(/"+host+"/nova.collector.cycle.ok)=0", 3),
        ("NOVA collector no CloudWatch series", "max(/"+host+"/nova.collector.cloudwatch.series.available,#2)=0", 3),
    ]
    for desc, expression, priority in checks:
        old = z.call("trigger.get", {"filter": {"description": [desc]}, "output": ["triggerid", "expression"]})
        if not old:
            z.call("trigger.create", {"description": desc, "expression": expression, "priority": priority,
                                      "tags": [{"tag": "managed-by", "value": "nova"}]})
        elif len(old) == 1 and old[0]["expression"] != expression:
            z.call("trigger.update", {"triggerid": old[0]["triggerid"], "expression": expression})
        elif len(old) != 1:
            raise ValueError("Ambiguous trigger")


def live_dashboard(doc, implemented):
    uid, title, panels = doc
    notice = ("**NOVA / Zabbix live** — AWS data is mirrored via the ECS collector. "
              "PENDENTE = source not implemented; HTTPS necessário = optional HTTPS probe; "
              "missing data is not zero. Full scope and original templates remain in monitoring/grafana.")
    out = [{"id": 1, "title": "Coleta e cobertura", "type": "text",
            "gridPos": {"x": 0, "y": 0, "w": 24, "h": 4},
            "options": {"mode": "markdown", "content": notice}}]
    for i, (name, unit, t) in enumerate(panels):
        out.append({"id": i+2, "title": name, "type": "timeseries", "datasource": DS,
                    "gridPos": {"x": (i%2)*12, "y": 4+(i//2)*8, "w": 12, "h": 8},
                    "fieldConfig": {"defaults": {"unit": unit, "noValue": "Sem dados",
                                                  "custom": {"spanNulls": False}}, "overrides": []},
                    "targets": [t], "options": {"legend": {"displayMode": "table", "placement": "bottom"}}})
    return {"id": None, "uid": "zbx-"+uid, "title": title+" | Zabbix", "schemaVersion": 39,
            "tags": ["nova", "zabbix-live", "managed"], "editable": True,
            "time": {"from": "now-6h", "to": "now"}, "refresh": "5m", "timezone": "browser",
            "templating": {"list": []}, "panels": out}


def ensure_original_dashboards(grafana, docs):
    folder = "nova-cloudwatch-originals"
    if grafana.call("/api/folders/" + folder) is None:
        grafana.call("/api/folders", "POST", {"uid": folder, "title": "NOVA | Original Dashboards"})
    for dashboard in docs:
        grafana.ensure_dashboard(dashboard, folder)
    print("NOVA original dashboards verified: %d" % len(docs), flush=True)


def ensure_dashboards(grafana, docs):
    folder = grafana.call("/api/folders/nova-zabbix-live")
    if folder is None:
        grafana.call("/api/folders", "POST", {"uid": "nova-zabbix-live", "title": "NOVA | Zabbix Live"})
    for doc in docs:
        grafana.ensure_dashboard(live_dashboard(doc, IMPLEMENTED), "nova-zabbix-live")


def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        data = sock.recv(n-len(buf))
        if not data:
            raise OSError("Zabbix sender connection closed")
        buf.extend(data)
    return bytes(buf)


def sender(rows):
    """Zabbix sender protocol, restricted to loopback in the ECS task."""
    for i in range(0, len(rows), 200):
        batch = rows[i:i+200]
        payload = json.dumps({"request": "sender data", "data": batch}).encode()
        with socket.create_connection(("127.0.0.1", 10051), timeout=12) as conn:
            conn.sendall(b"ZBXD\x01" + struct.pack("<Q", len(payload)) + payload)
            header = recv_exact(conn, 13)
            if header[:5] != b"ZBXD\x01":
                raise OSError("Unexpected Zabbix sender response")
            size = struct.unpack("<Q", header[5:])[0]
            if size > 65536:
                raise OSError("Oversized Zabbix sender response")
            response = json.loads(recv_exact(conn, size))
        info = response.get("info", "")
        counts = re.search(r"processed:\s*(\d+);\s*failed:\s*(\d+);\s*total:\s*(\d+)", info)
        if response.get("response") != "success" or not counts or tuple(map(int, counts.groups())) != (len(batch), 0, len(batch)):
            raise RuntimeError("Zabbix sender did not accept entire batch")


def row(host, key, value, clock):
    n = number(value)
    return None if n is None else {"host": host, "key": key, "value": str(n), "clock": clock}


def put(out, key, value, clock):
    host = "NOVA-D" + key.split(".")[1][1:]
    sample = row(host, key, value, clock)
    if sample is not None:
        out.append(sample)


def age(now, value):
    return max(0, (now - parse_date(value)).total_seconds()) if value else None


def rds_inventory(aws, variables, now, out):
    clock = int(now.timestamp())
    counts, public = [], []
    for suffix, var, backup_key in (("13", "appdb", "app"), ("14", "mondb", "monitoring")):
        ident = variables[var]
        root = aws.query("rds", "DescribeDBInstances", "2014-10-31", {"DBInstanceIdentifier": ident})
        instance = root.find(".//DBInstances/DBInstance")
        if instance is None:
            raise ValueError("Expected RDS instance missing")
        prefix = "nova.d"+suffix+"."
        status = instance.findtext("DBInstanceStatus")
        if status:
            put(out, prefix+"db_available", int(status == "available"), clock)
        exposed = instance.findtext("PubliclyAccessible")
        if exposed not in ("true", "false"):
            raise ValueError("RDS missing exposure state")
        public.append(exposed == "true")
        put(out, prefix+"db_latest_restorable_age_seconds", age(now, instance.findtext("LatestRestorableTime")), clock)
        params = {"DBInstanceIdentifier": ident, "SnapshotType": "automated"}
        found = []
        for _ in range(20):
            root = aws.query("rds", "DescribeDBSnapshots", "2014-10-31", params)
            found.extend(root.findall(".//DBSnapshots/DBSnapshot"))
            marker = root.findtext(".//Marker")
            if not marker:
                break
            params["Marker"] = marker
        else:
            raise RuntimeError("RDS snapshot pagination limit")
        counts.append(len(found))
        times = [parse_date(s.findtext("SnapshotCreateTime")) for s in found
                 if s.findtext("Status") == "available" and s.findtext("SnapshotCreateTime")]
        if times:
            seconds = max(0, (now-max(times)).total_seconds())
            put(out, prefix+"db_backup_age_seconds", seconds, clock)
            put(out, "nova.d21."+backup_key+"_backup_age_seconds", seconds, clock)
    put(out, "nova.d21.snapshot_count", sum(counts), clock)
    # Scope: only the two project RDS instances; not all public resources.
    # RDS exposure only; leave the broader SOC contract pending.


def network_inventory(aws, variables, now, out):
    clock = int(now.timestamp())
    vpc = variables.get("vpc")
    if not vpc:
        return
    params = {"Filter.1.Name": "vpc-id", "Filter.1.Value.1": vpc}
    subnets = aws.query("ec2", "DescribeSubnets", "2016-11-15", params)
    routes = aws.query("ec2", "DescribeRouteTables", "2016-11-15", params)
    nats = aws.query("ec2", "DescribeNatGateways", "2016-11-15",
                     {"Filter.1.Name": "vpc-id", "Filter.1.Value.1": vpc})
    if any(x.findtext(".//nextToken") for x in (subnets, routes, nats)):
        raise RuntimeError("Network inventory pagination required")
    sub = subnets.findall(".//subnetSet/item")
    free, capacity = [], []
    for s in sub:
        free.append(int(s.findtext("availableIpAddressCount")))
        capacity.append(ipaddress.ip_network(s.findtext("cidrBlock")).num_addresses-5)
    if sub and sum(capacity)>0:
        put(out, "nova.d08.subnet_free_ips", sum(free), clock)
        put(out, "nova.d08.subnet_ip_utilization_pct", 100*(1-sum(free)/sum(capacity)), clock)
    tables = routes.findall(".//routeTableSet/item")
    if tables:
        put(out, "nova.d08.blackhole_routes", sum(r.findtext("state")=="blackhole"
            for t in tables for r in t.findall("routeSet/item")), clock)
    gateways = nats.findall(".//natGatewaySet/item")
    expected = {variables.get("nat_a"), variables.get("nat_b"), variables.get("nat_c")} - {None, ""}
    if expected:
        put(out, "nova.d09.nat_available", sum(g.findtext("state")=="available" and
            g.findtext("natGatewayId") in expected for g in gateways), clock)


def target_inventory(aws, variables, now, out):
    clock = int(now.timestamp())
    arns = variables.get("target_arns", [])
    if not arns:
        return
    states = []
    for arn in arns:
        r = aws.query("elasticloadbalancing", "DescribeTargetHealth", "2015-12-01", {"TargetGroupArn": arn})
        states.extend(x.findtext("TargetHealth/State") for x in r.findall(".//TargetHealthDescriptions/member"))
    put(out, "nova.d07.registered_targets", len(states), clock)
    put(out, "nova.d07.draining_targets", states.count("draining"), clock)


def ecr_inventory(aws, variables, now, out):
    clock = int(now.timestamp())
    images = []
    for repository in variables.get("ecr_repositories", []):
        params = {"repositoryName": repository, "maxResults": 100}
        for _ in range(20):
            response = aws.json_api("ecr", "AmazonEC2ContainerRegistry_V20150921.DescribeImages", params)
            images.extend(response.get("imageDetails", []))
            token = response.get("nextToken")
            if not token:
                break
            params["nextToken"] = token
        else:
            raise RuntimeError("ECR pagination limit")
    if variables.get("ecr_repositories"):
        put(out, "nova.d26.image_count", len(images), clock)
        sizes = [number(x.get("imageSizeInBytes")) for x in images]
        if all(s is not None for s in sizes):
            put(out, "nova.d26.image_bytes", sum(sizes), clock)
        put(out, "nova.d26.untagged_images", sum(not x.get("imageTags") for x in images), clock)


def zabbix_inventory(z, groupid, now, out):
    clock = int(now.timestamp())
    g = z.call("hostgroup.get", {"filter": {"name": [GROUP, "NOVA Monitoring"]}, "output": ["groupid"]})
    ids = [x["groupid"] for x in g] or [groupid]
    put(out, "nova.d01.active_incidents", z.call("problem.get", {"groupids": ids, "countOutput": True}), clock)
    put(out, "nova.d17.zabbix_unsupported_items", z.call("item.get", {"groupids": ids, "filter": {"state": 1}, "countOutput": True}), clock)


def https_probe(variables, now, out):
    url = variables.get("https_url", "")
    if not url.startswith("https://"):
        return
    started = time.monotonic()
    try:
        with urlopen(Request(url.rstrip("/")+"/", method="GET"), timeout=10) as response:
            status = response.status
    except HTTPError as exc:
        status = exc.code
    clock = int(now.timestamp())
    elapsed = time.monotonic()-started
    for key in ("nova.d06.external_http_status", "nova.d10.frontend_http_status"):
        put(out, key, status, clock)
    for key in ("nova.d06.external_http_latency_seconds", "nova.d10.frontend_ttfb_seconds"):
        put(out, key, elapsed, clock)


def nat_ratios(specs, values, now, out):
    # Align samples on the same complete five-minute bucket; never substitute zeros.
    by = {}
    for key, spec in specs.items():
        if spec["namespace"] == "AWS/NATGateway" and key in values:
            nat = spec["dimensions"].get("NatGatewayId")
            by.setdefault(nat, {})[spec["metricName"]] = values[key]
    expected = {spec["dimensions"].get("NatGatewayId") for spec in specs.values()
                if spec["namespace"] == "AWS/NATGateway"} - {None, ""}
    for key, numerator, denoms in (
        ("nova.d09.nat_packet_drop_pct", "PacketsDropCount", ["PacketsInFromSource", "PacketsInFromDestination"]),
    ):
        if not expected or not expected.issubset(by):
            continue
        sets = [by[n].get(metric, {}) for n in expected for metric in [numerator, *denoms]]
        common = set.intersection(*(set(s) for s in sets)) if sets else set()
        if not common:
            continue
        ts = max(common)
        numer = sum(by[n][numerator][ts] for n in expected)
        denom = sum(by[n][m][ts] for n in expected for m in denoms)
        if denom > 0:
            # Connection-established and attempts can be staggered across buckets;
            # this is a ratio of observed counts, not a per-connection success SLI.
            put(out, key, 100*numer/denom, ts)


def run():
    catalog = decode_catalog(os.environ["NOVA_ZABBIX_CATALOG_B64"])
    variables = json.loads(os.environ["NOVA_RESOURCE_VARS"])
    interval = max(300, min(3600, int(os.getenv("NOVA_COLLECTION_SECONDS", "900"))))
    specs, items, docs = inventory(catalog, variables)
    password = os.getenv("ZABBIX_PASSWORD") or hashlib.sha256(
        ("NOVA-ZABBIX:"+os.environ["GRAFANA_PASSWORD"]).encode()).hexdigest()
    z = bootstrap.Zabbix(os.environ["ZABBIX_URL"])
    grafana = bootstrap.Grafana(os.environ["GRAFANA_URL"], os.environ["GRAFANA_PASSWORD"])
    aws = AWS(variables["region"])
    last = {}
    groupid = None
    last_success = None
    provisioned = False
    while True:
        start = time.monotonic()
        try:
            if not provisioned:
                z.token = z.login(password)
                groupid = ensure_items(z, items)
                ensure_triggers(z, interval)
                ensure_dashboards(grafana, docs)
                if os.getenv("NOVA_DASHBOARD_BUCKET"):
                    original = aws.dashboard_bundle(os.environ["NOVA_DASHBOARD_BUCKET"], os.environ["NOVA_DASHBOARD_SHA256"])
                    ensure_original_dashboards(grafana, original)
                # Zabbix server configuration cache may lag newly created trappers.
                time.sleep(70)
                restore_cursors(z, items, last)
                provisioned = True
                print("NOVA Zabbix collector ready: %d unique CloudWatch queries; %d dashboards; %d planned contract producers" %
                      (len(specs), len(docs), len(IMPLEMENTED)), flush=True)
            now = utc()
            clock = int(now.timestamp())
            samples = []
            errors = 0
            values = {}
            try:
                values = aws.metric_data(specs, now)
                for key, data in values.items():
                    for ts, val in sorted(data.items()):
                        if ts > last.get((AWS_HOST, key), 0):
                            samples.append(row(AWS_HOST, key, val, ts))
                nat_ratios(specs, values, now, samples)
            except Exception as exc:
                errors += 1
                print("NOVA CloudWatch collection failed: "+type(exc).__name__, flush=True)
            for fn in (rds_inventory, network_inventory, target_inventory, ecr_inventory):
                try:
                    fn(aws, variables, now, samples)
                except Exception as exc:
                    errors += 1
                    print("NOVA "+fn.__name__+" failed: "+type(exc).__name__, flush=True)
            try:
                zabbix_inventory(z, groupid, now, samples)
            except Exception as exc:
                errors += 1
                print("NOVA Zabbix inventory failed: "+type(exc).__name__, flush=True)
                z.token = z.login(password)
            try:
                https_probe(variables, now, samples)
            except Exception as exc:
                errors += 1
                print("NOVA HTTPS probe failed: "+type(exc).__name__, flush=True)
            if last_success is not None:
                put(samples, "nova.d01.last_collection_age", clock-last_success, clock)
            # Only send defined, numeric, newer samples. No fake zeros and no repeat of old CW timestamps.
            # Deduplicate within a cycle as multiple producers may overlap.
            unique = {}
            for sample in samples:
                if sample and (sample["host"], sample["key"]) in items:
                    pair = (sample["host"], sample["key"])
                    if sample["clock"] > last.get(pair, 0):
                        unique[(*pair, sample["clock"])] = sample
            samples = sorted(unique.values(), key=lambda s: (s["host"], s["key"], s["clock"]))
            expected = sum(all(s["dimensions"].values()) for s in specs.values())
            for key, v in (("heartbeat", 1), ("cycle.ok", int(errors == 0 and bool(values))),
                           ("cloudwatch.series.available", len(values)),
                           ("cloudwatch.series.expected", expected), ("source.errors", errors)):
                samples.append(row(CONTROL, "nova.collector."+key, v, clock))
            # Commit cursors only for batches acknowledged by Zabbix.
            for i in range(0, len(samples), 200):
                batch = samples[i:i+200]
                sender(batch)
                for s in batch:
                    last[(s["host"], s["key"])] = max(last.get((s["host"], s["key"]), 0), s["clock"])
            if errors == 0 and values:
                last_success = clock
                with open("/tmp/nova-monitoring-ready", "w", encoding="utf-8") as ready:
                    ready.write(str(clock) + "\\n")
            print("NOVA collection: series=%d/%d, samples=%d, errors=%d" %
                  (len(values), expected, len(samples), errors), flush=True)
            if errors == 0 and values:
                print("NOVA monitoring verification passed", flush=True)
            else:
                try:
                    os.unlink("/tmp/nova-monitoring-ready")
                except FileNotFoundError:
                    pass
        except Exception as exc:
            # Keep the original monitoring task available; retry without exposing credentials.
            print("NOVA collector retry: "+type(exc).__name__, flush=True)
            # Sender may have accepted part of a batch. Reconcile from Zabbix
            # on the next cycle rather than blindly re-sending it.
            provisioned = False
            try:
                os.unlink("/tmp/nova-monitoring-ready")
            except FileNotFoundError:
                pass
        time.sleep(max(5, interval-(time.monotonic()-start)))


if __name__ == "__main__":
    run()
