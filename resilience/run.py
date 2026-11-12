#!/usr/bin/env python3
"""NOVA resilience demonstrations. Read-only by default; one explicitly guarded ECS task exercise."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ACCOUNT = "996560371158"
REGION = "us-east-1"
CLUSTER = "cloudstart-dev-cluster"
PREFIX = "cloudstart-dev"
ALB_NAME = PREFIX + "-alb"
SERVICES = ("frontend", "backend")
ALL_SERVICES = SERVICES + ("monitoring",)
TARGET_GROUPS = {"frontend": PREFIX + "-frontend-tg", "backend": PREFIX + "-backend-tg", "monitoring": PREFIX + "-grafana-tg"}
PATHS = ("/", "/health", "/api/health", "/api/health/db", "/grafana/api/health")
EVENTS: list[dict] = []
FAILS = 0
WARNINGS = 0


def record(kind: str, label: str, detail: str = "") -> None:
    global FAILS, WARNINGS
    if kind == "FAIL":
        FAILS += 1
    if kind == "WARN":
        WARNINGS += 1
    EVENTS.append({"kind": kind, "label": label, "detail": detail})
    print(f"[{kind:4}] {label}: {detail}", flush=True)


def aws(*args: str) -> dict:
    proc = subprocess.run(
        ["aws", *args, "--region", REGION, "--output", "json", "--no-cli-pager"],
        capture_output=True, text=True, timeout=40, check=False,
        env={**os.environ, "AWS_PAGER": ""},
    )
    if proc.returncode != 0:
        raise RuntimeError(f"AWS query failed for {' '.join(args[:2])}: {proc.stderr.strip()[:180]}")
    return json.loads(proc.stdout)


def guarded_identity() -> None:
    who = aws("sts", "get-caller-identity")
    if who.get("Account") != ACCOUNT:
        raise RuntimeError("Wrong AWS account. No tests executed.")
    record("PASS", "AWS account guard", ACCOUNT)


def get_service(service: str) -> dict:
    data = aws("ecs", "describe-services", "--cluster", CLUSTER,
               "--services", PREFIX + "-" + service)
    items = data.get("services", [])
    if len(items) != 1 or data.get("failures"):
        raise RuntimeError("ECS service not found: " + service)
    return items[0]


def running_tasks(service: str) -> list[dict]:
    listing = aws("ecs", "list-tasks", "--cluster", CLUSTER,
                  "--service-name", PREFIX + "-" + service, "--desired-status", "RUNNING")
    arns = listing.get("taskArns", [])
    if not arns:
        return []
    result = []
    for i in range(0, len(arns), 10):
        details = aws("ecs", "describe-tasks", "--cluster", CLUSTER, "--tasks", *arns[i:i+10])
        result.extend(details.get("tasks", []))
    return result


def target_health(service: str) -> tuple[int, int, list[dict]]:
    groups = aws("elbv2", "describe-target-groups", "--names", TARGET_GROUPS[service]).get("TargetGroups", [])
    if len(groups) != 1:
        raise RuntimeError("Missing target group " + service)
    health = aws("elbv2", "describe-target-health", "--target-group-arn", groups[0]["TargetGroupArn"])
    targets = health.get("TargetHealthDescriptions", [])
    return (sum(t.get("TargetHealth", {}).get("State") == "healthy" for t in targets),
            sum(t.get("TargetHealth", {}).get("State") not in ("healthy", "draining") for t in targets),
            targets)


def alb_url() -> str:
    lbs = aws("elbv2", "describe-load-balancers", "--names", ALB_NAME).get("LoadBalancers", [])
    if len(lbs) != 1 or lbs[0].get("State", {}).get("Code") != "active":
        raise RuntimeError("ALB not active")
    return "http://" + lbs[0]["DNSName"]


def http_code(url: str) -> int:
    try:
        with urlopen(Request(url, headers={"User-Agent": "NOVA-Resilience-Probe/1.0"}), timeout=8) as res:
            res.read(128)
            return res.status
    except HTTPError as exc:
        return exc.code
    except (URLError, TimeoutError, OSError):
        return 0


def baseline() -> None:
    try:
        base = alb_url()
        record("PASS", "ALB", base)
    except Exception as exc:
        record("FAIL", "ALB", str(exc))
        base = ""
    for name in ALL_SERVICES:
        try:
            s = get_service(name)
            desired, running, pending = (int(s.get(k, 0)) for k in ("desiredCount", "runningCount", "pendingCount"))
            deployments = s.get("deployments", [])
            stable = (desired > 0 and running == desired and pending == 0 and
                      len(deployments) == 1 and deployments[0].get("rolloutState") == "COMPLETED")
            record("PASS" if stable else "FAIL", "ECS " + name,
                   f"desired={desired} running={running} pending={pending} deployments={len(deployments)}")
            healthy, nonhealthy, _ = target_health(name)
            record("PASS" if healthy >= desired and nonhealthy == 0 else "FAIL",
                   "ALB targets " + name, f"healthy={healthy} expected={desired} other_unhealthy={nonhealthy}")
        except Exception as exc:
            record("FAIL", "ECS/ALB " + name, str(exc))
    for db in (PREFIX + "-db", PREFIX + "-monitoring-db"):
        try:
            matches = aws("rds", "describe-db-instances", "--db-instance-identifier", db).get("DBInstances", [])
            state = matches[0].get("DBInstanceStatus") if matches else "missing"
            record("PASS" if state == "available" else "FAIL", "RDS " + db, str(state))
        except Exception as exc:
            record("FAIL", "RDS " + db, str(exc))
    if base:
        for path in PATHS:
            code = http_code(base + path)
            expected = {200, 301, 302, 307, 308} if path == "/" else {200}
            record("PASS" if code in expected else "FAIL", "HTTP " + path, f"code={code}")


def load_balancer_demo() -> None:
    """A few sequential requests, not a load test or denial-of-service simulation."""
    base = alb_url()
    for service in ALL_SERVICES:
        healthy, _, targets = target_health(service)
        registered = len([t for t in targets if t.get("TargetHealth", {}).get("State") == "healthy"])
        record("PASS" if healthy >= (2 if service in SERVICES else 1) else "FAIL",
               "Distribution target pool " + service, f"{registered} healthy targets")
    successes = 0
    for i in range(12):
        code = http_code(base + PATHS[i % len(PATHS)])
        successes += code in (200, 301, 302, 307, 308)
        time.sleep(0.2)
    record("PASS" if successes == 12 else "FAIL", "Bounded ALB sample",
           f"{successes}/12 successful HTTP responses (sequential; no stress generated)")
    record("WARN", "Distribution caveat",
           "ALB target registration/health proven; request placement per target requires access logs.")


def autoscaling_demo() -> None:
    for service in SERVICES:
        try:
            resource_id = f"service/{CLUSTER}/{PREFIX}-{service}"
            result = aws("application-autoscaling", "describe-scalable-targets", "--service-namespace", "ecs",
                         "--resource-ids", resource_id).get("ScalableTargets", [])
            policies = aws("application-autoscaling", "describe-scaling-policies", "--service-namespace", "ecs",
                           "--resource-id", resource_id).get("ScalingPolicies", [])
            if len(result) != 1:
                record("FAIL", "Autoscaling " + service, "no scalable target")
                continue
            target = result[0]
            minimum, maximum = target["MinCapacity"], target["MaxCapacity"]
            records = [p.get("PolicyName", "") for p in policies if p.get("PolicyType") == "TargetTrackingScaling"]
            okay = minimum >= 2 and maximum > minimum and len(records) >= 2
            record("PASS" if okay else "FAIL", "Autoscaling configuration " + service,
                   f"min={minimum} max={maximum} target-tracking={len(records)}")
        except Exception as exc:
            record("FAIL", "Autoscaling " + service, str(exc))
    record("WARN", "Scaling behavior not exercised",
           "This test validates policies/bounds only. No artificial CPU load or scaling event is generated.")


def az_readiness_demo() -> None:
    try:
        lb = aws("elbv2", "describe-load-balancers", "--names", ALB_NAME)["LoadBalancers"][0]
        zones = {x.get("ZoneName") for x in lb.get("AvailabilityZones", [])}
        record("PASS" if len(zones) >= 2 else "FAIL", "ALB multi-AZ", ",".join(sorted(zones)))
    except Exception as exc:
        record("FAIL", "ALB multi-AZ", str(exc))
    for service in SERVICES:
        try:
            tasks = running_tasks(service)
            subnets = []
            for task in tasks:
                for attachment in task.get("attachments", []):
                    for entry in attachment.get("details", []):
                        if entry.get("name") == "subnetId":
                            subnets.append(entry.get("value"))
            if not subnets:
                record("WARN", "Task AZ spread " + service, "subnet metadata unavailable")
                continue
            subnets = sorted(set(subnets))
            details = aws("ec2", "describe-subnets", "--subnet-ids", *subnets)["Subnets"]
            zones = {s.get("AvailabilityZone") for s in details}
            record("PASS" if len(zones) >= 2 else "WARN", "Task AZ spread " + service,
                   ",".join(sorted(zones)) + " (placement observation only)")
        except Exception as exc:
            record("FAIL", "Task AZ spread " + service, str(exc))
    for db in (PREFIX + "-db", PREFIX + "-monitoring-db"):
        try:
            obj = aws("rds", "describe-db-instances", "--db-instance-identifier", db)["DBInstances"][0]
            record("PASS" if obj.get("MultiAZ") else "WARN", "RDS zone resilience " + db,
                   f"MultiAZ={obj.get('MultiAZ', False)}")
        except Exception as exc:
            record("FAIL", "RDS zone resilience " + db, str(exc))
    record("WARN", "Region outage",
           "Single-region deployment in us-east-1. No cross-region failover is configured; region outage NOT simulated.")


def task_recovery(service: str, phrase: str) -> None:
    """Opt-in single-task ECS fault injection for OWN dev cluster; never run unattended."""
    if service not in SERVICES:
        raise RuntimeError("Only frontend/backend are eligible; monitoring is excluded.")
    expected = f"STOP ONE {service.upper()} TASK"
    if phrase != expected:
        raise RuntimeError("Missing exact confirmation: " + expected)
    s = get_service(service)
    tasks = running_tasks(service)
    healthy, unhealthy, _ = target_health(service)
    if (s.get("desiredCount") != 2 or s.get("runningCount") != 2 or s.get("pendingCount") != 0 or
        len(s.get("deployments", [])) != 1 or len(tasks) != 2 or healthy != 2 or unhealthy != 0 or
        any(t.get("lastStatus") != "RUNNING" or t.get("healthStatus") != "HEALTHY" for t in tasks)):
        raise RuntimeError("Preconditions failed: require exactly 2/2 healthy tasks and a stable deployment.")
    selected = sorted(tasks, key=lambda t: t["taskArn"])[0]["taskArn"]
    base = alb_url()
    path = "/" if service == "frontend" else "/api/health"
    if http_code(base + path) != 200:
        raise RuntimeError("HTTP endpoint not healthy before experiment.")
    record("PASS", "Fault-injection preflight", f"{service} 2/2 healthy, HTTP 200")
    record("WARN", "Authorized single-task stop",
           "One ECS task will be stopped; brief disruption or AWS charges are possible.")
    aws("ecs", "stop-task", "--cluster", CLUSTER, "--task", selected,
        "--reason", "NOVA controlled single-task recovery demonstration")
    record("PASS", "Fault injected", "Stopped exactly one " + service + " task")
    deadline = time.monotonic() + 480
    probes = 0
    http_errors = 0
    recovered = False
    while time.monotonic() < deadline:
        code = http_code(base + path)
        probes += 1
        http_errors += code != 200
        try:
            tasks = running_tasks(service)
            state = get_service(service)
            healthy, unhealthy, _ = target_health(service)
            recovered = (selected not in {t["taskArn"] for t in tasks} and
                         len(tasks) == 2 and state.get("runningCount") == 2 and
                         state.get("pendingCount") == 0 and healthy == 2 and unhealthy == 0 and
                         all(t.get("healthStatus") == "HEALTHY" for t in tasks))
            if recovered:
                break
        except Exception as exc:
            record("WARN", "Poll query", str(exc))
        time.sleep(12)
    record("PASS" if recovered else "FAIL", "ECS automatic replacement",
           f"recovered={recovered} | task_count={len(tasks)}")
    record("PASS" if http_errors == 0 else "WARN", "Availability during recovery",
           f"HTTP probes={probes}, unsuccessful={http_errors}; service may have served transient errors")
    if not recovered:
        record("WARN", "Follow-up", "Inspect ECS events/target health; no automatic retries or additional faults.")


def write_report(folder: str) -> None:
    path = Path(folder)
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    result = {
        "project": "NOVA", "account": ACCOUNT, "region": REGION, "date_utc": stamp,
        "pass": sum(e["kind"] == "PASS" for e in EVENTS),
        "warnings": WARNINGS, "failures": FAILS, "events": EVENTS,
    }
    dest = path / ("resilience-" + stamp + ".json")
    dest.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    os.chmod(dest, 0o600)
    print("Report:", dest)


def main() -> int:
    parser = argparse.ArgumentParser(description="NOVA resilience evidence (read-only unless explicit task-recovery)")
    parser.add_argument("suite", choices=["all", "baseline", "alb", "autoscaling", "az", "task-recovery"])
    parser.add_argument("--service", choices=SERVICES)
    parser.add_argument("--confirm", default="")
    parser.add_argument("--report-dir", default=".deploy/resilience")
    args = parser.parse_args()
    if args.suite == "task-recovery" and (not args.service or
            args.confirm != f"STOP ONE {args.service.upper()} TASK"):
        parser.error("task-recovery requires --service and exact --confirm phrase")
    if args.suite != "task-recovery" and (args.service or args.confirm):
        parser.error("--service/--confirm only valid for task-recovery")
    try:
        guarded_identity()
        if args.suite in ("all", "baseline"):
            baseline()
        if args.suite in ("all", "alb"):
            load_balancer_demo()
        if args.suite in ("all", "autoscaling"):
            autoscaling_demo()
        if args.suite in ("all", "az"):
            az_readiness_demo()
        if args.suite == "task-recovery":
            task_recovery(args.service, args.confirm)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        record("FAIL", "Suite interrupted", str(exc))
    finally:
        try:
            write_report(args.report_dir)
        except OSError as exc:
            record("WARN", "Report writing failed", str(exc))
    print(f"RESULT: PASS={sum(e['kind']=='PASS' for e in EVENTS)} WARN={WARNINGS} FAIL={FAILS}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
