#!/usr/bin/env python3
"""Read-only preflight for overlapping NOVA Terraform state ownership.

Does not import, forget, modify, or delete AWS resources or Terraform state.
A legacy state snapshot is not proof that its resources still exist: verify
the exact name/ID against AWS before blocking a deployment.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

RESOURCE_TYPES = {
    "aws_lb_target_group",
    "aws_db_subnet_group",
    "aws_iam_role",
    "aws_secretsmanager_secret",
    "aws_ecr_repository",
    "aws_ecs_cluster",
}

MISSING_ERRORS = {
    "TargetGroupNotFound",
    "DBSubnetGroupNotFound",
    "NoSuchEntity",
    "ResourceNotFoundException",
    "RepositoryNotFoundException",
    "ClusterNotFoundException",
}


def aws(*arguments: str, allow_missing: bool = False) -> dict | None:
    cmd = ["aws", *arguments, "--output", "json", "--no-cli-pager"]
    result = subprocess.run(cmd, text=True, capture_output=True, check=False)
    if result.returncode:
        if allow_missing and any(code in result.stderr for code in MISSING_ERRORS):
            return None
        raise RuntimeError(
            f"AWS read failed for {arguments[0]} {arguments[1]} "
            f"(exit {result.returncode}): {result.stderr.strip()[:500]}"
        )
    return json.loads(result.stdout) if result.stdout.strip() else {}


def objects(state: dict):
    for resource in state.get("resources", []):
        if resource.get("mode") != "managed":
            continue
        for instance in resource.get("instances", []):
            attributes = instance.get("attributes") or {}
            if not isinstance(attributes, dict):
                continue
            yield resource.get("type", ""), resource.get("name", ""), attributes


def identity(attributes: dict) -> str:
    return str(attributes.get("id") or attributes.get("arn") or "")


def display_name(resource_type: str, attributes: dict) -> str:
    if resource_type == "aws_ecs_cluster":
        return str(attributes.get("name") or attributes.get("cluster_name") or "")
    return str(attributes.get("name") or "")


def canonical_vpc(state: dict) -> str:
    for kind, name, attributes in objects(state):
        if kind == "aws_vpc" and name == "this":
            return identity(attributes)
    return ""


def analyze(canonical: dict, legacy_states: dict, read_live):
    """Return errors/warnings; read_live(kind, name) returns id and optional vpc."""
    current = {(kind, identity(a)) for kind, _, a in objects(canonical) if identity(a)}
    active_vpc = canonical_vpc(canonical)
    errors: list[str] = []
    notices: list[str] = []
    checked: set[tuple[str, str]] = set()

    for state_key, state in legacy_states.items():
        for kind, address, attrs in objects(state):
            if kind not in RESOURCE_TYPES:
                continue
            name = display_name(kind, attrs)
            if not name or (kind, name) in checked:
                continue
            checked.add((kind, name))
            actual = read_live(kind, name)
            if actual is None:
                notices.append(f"STALE: {state_key} {kind}.{address} ({name}) no longer exists")
                continue
            live_id = str(actual.get("id") or "")
            if not live_id:
                raise RuntimeError(f"Missing identity in live AWS lookup: {kind} {name}")
            legacy_id = identity(attrs)
            mismatch = bool(legacy_id and legacy_id != live_id)
            related_vpc = str(actual.get("vpc") or "")
            cross_vpc = bool(active_vpc and related_vpc and active_vpc != related_vpc)
            already_current = (kind, live_id) in current
            labels = []
            if mismatch:
                labels.append("STALE_ID")
            if cross_vpc:
                labels.append(f"FOREIGN_VPC={related_vpc} (canonical={active_vpc})")
            if already_current:
                labels.append("DOUBLE_STATE_OWNERSHIP")
            else:
                labels.append("NOT_IN_CANONICAL_STATE")
            errors.append(
                f"BLOCKED: {kind}.{address} name={name} legacy={state_key} "
                + " ".join(labels)
            )

    return errors, notices


def load_state(bucket: str, key: str, region: str, account: str) -> dict | None:
    with tempfile.TemporaryDirectory(prefix="nova-state-audit-") as folder:
        output_path = Path(folder) / "state.json"
        cmd = [
            "aws", "s3api", "get-object",
            "--bucket", bucket, "--key", key,
            "--expected-bucket-owner", account,
            "--region", region, str(output_path),
            "--output", "json", "--no-cli-pager",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if result.returncode:
            if "NoSuchKey" in result.stderr or "404" in result.stderr:
                return None
            raise RuntimeError(f"Unable to read state {key}: {result.stderr.strip()[:500]}")
        return json.loads(output_path.read_text(encoding="utf-8"))


def live_lookup(region: str):
    def lookup(kind: str, name: str) -> dict | None:
        common = ("--region", region)
        if kind == "aws_lb_target_group":
            data = aws("elbv2", "describe-target-groups", "--names", name,
                       *common, allow_missing=True)
            items = data.get("TargetGroups", []) if data else []
            return {"id": items[0]["TargetGroupArn"], "vpc": items[0].get("VpcId")} if items else None
        if kind == "aws_db_subnet_group":
            data = aws("rds", "describe-db-subnet-groups", "--db-subnet-group-name",
                       name, *common, allow_missing=True)
            items = data.get("DBSubnetGroups", []) if data else []
            return {"id": items[0]["DBSubnetGroupName"], "vpc": items[0].get("VpcId")} if items else None
        if kind == "aws_iam_role":
            data = aws("iam", "get-role", "--role-name", name, allow_missing=True)
            role = data.get("Role") if data else None
            return {"id": role["RoleName"]} if role else None
        if kind == "aws_secretsmanager_secret":
            data = aws("secretsmanager", "describe-secret", "--secret-id", name,
                       *common, allow_missing=True)
            return {"id": data["ARN"]} if data and not data.get("DeletedDate") else None
        if kind == "aws_ecr_repository":
            data = aws("ecr", "describe-repositories", "--repository-names", name,
                       *common, allow_missing=True)
            items = data.get("repositories", []) if data else []
            return {"id": items[0]["repositoryName"]} if items else None
        if kind == "aws_ecs_cluster":
            data = aws("ecs", "describe-clusters", "--clusters", name,
                       *common, allow_missing=True)
            items = [c for c in data.get("clusters", []) if c.get("status") == "ACTIVE"] if data else []
            return {"id": items[0]["clusterArn"]} if items else None
        raise RuntimeError(f"Unknown resource kind {kind}")
    return lookup


def main() -> int:
    account = os.environ.get("EXPECTED_AWS_ACCOUNT_ID", "")
    region = os.environ.get("AWS_REGION", "")
    bucket = os.environ.get("TF_STATE_BUCKET", "")
    key = os.environ.get("TF_STATE_KEY", "")
    if not all((account, region, bucket, key)):
        raise RuntimeError("Missing AWS_REGION, EXPECTED_AWS_ACCOUNT_ID, TF_STATE_BUCKET or TF_STATE_KEY")
    caller = aws("sts", "get-caller-identity")
    if str(caller["Account"]) != account:
        raise RuntimeError(f"Wrong AWS account {caller['Account']}; expected {account}")
    canonical = load_state(bucket, key, region, account) or {"resources": []}
    legacy = {}
    for legacy_key in os.environ.get("LEGACY_TF_STATE_KEYS", "").split(","):
        legacy_key = legacy_key.strip()
        if not legacy_key or legacy_key == key:
            continue
        state = load_state(bucket, legacy_key, region, account)
        if state is not None:
            legacy[legacy_key] = state
    errors, notices = analyze(canonical, legacy, live_lookup(region))
    print(f"NOVA state ownership preflight: canonical={key}, legacy_states={len(legacy)}")
    for line in notices:
        print(line)
    for line in errors:
        print(line, file=sys.stderr)
    if errors:
        print(
            "STOP: existing AWS resources are recorded in legacy state(s). "
            "Do not apply a duplicate baseline or import resources from another VPC. "
            "Use the NOVA state recovery runbook; no AWS mutations were performed by preflight.",
            file=sys.stderr,
        )
        return 2
    print("PASS: no live overlaps detected in inspected legacy state resources.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError, json.JSONDecodeError) as error:
        print(f"ERROR: state ownership preflight could not complete: {error}", file=sys.stderr)
        sys.exit(1)
