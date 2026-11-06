#!/usr/bin/env python3
"""Verify narrow in-place Terraform updates after NOVA legacy State imports."""
import json
from pathlib import Path
import sys

ROLES = frozenset({
    "aws_iam_role.ecs_backend_task",
    "aws_iam_role.ecs_execution",
    "aws_iam_role.ecs_frontend_task",
    "aws_iam_role.ecs_monitoring_execution",
    "aws_iam_role.ecs_monitoring_task",
})
SECRET = "aws_secretsmanager_secret.grafana_admin"
ROLE_FIELDS = frozenset({"tags", "tags_all", "assume_role_policy"})
SECRET_FIELDS = frozenset({"tags", "tags_all", "recovery_window_in_days", "force_overwrite_replica_secret"})


def valid_ecs_trust(value):
    if not isinstance(value, str):
        return False
    try:
        policy = json.loads(value)
    except (ValueError, TypeError):
        return False
    if not isinstance(policy, dict) or set(policy) != {"Version", "Statement"}:
        return False
    statements = policy["Statement"]
    if policy["Version"] != "2012-10-17" or not isinstance(statements, list) or len(statements) != 1:
        return False
    statement = statements[0]
    if not isinstance(statement, dict) or set(statement) - {"Sid", "Effect", "Action", "Principal"}:
        return False
    if statement.get("Sid") not in (None, "") or statement.get("Effect") != "Allow":
        return False
    action = statement.get("Action")
    if action not in ("sts:AssumeRole", ["sts:AssumeRole"]):
        return False
    principal = statement.get("Principal")
    if not isinstance(principal, dict) or set(principal) != {"Service"}:
        return False
    service = principal["Service"]
    return service == "ecs-tasks.amazonaws.com" or service == ["ecs-tasks.amazonaws.com"]


def check(plan, address):
    if address not in ROLES and address != SECRET:
        return False, "resource not in recovered inventory"
    matches = [r for r in plan.get("resource_changes", [])
               if r.get("address") == address and r.get("mode") == "managed"]
    if len(matches) != 1:
        return False, "ambiguous/missing resource"
    change = matches[0].get("change", {})
    if change.get("actions") != ["update"] or change.get("replace_paths") not in (None, []):
        return False, "not an in-place update"
    before, after = change.get("before"), change.get("after")
    if not isinstance(before, dict) or not isinstance(after, dict):
        return False, "missing planned values"
    modified = {k for k in before.keys() | after.keys() if before.get(k) != after.get(k)}
    allowed = ROLE_FIELDS if address in ROLES else SECRET_FIELDS
    if not modified or not modified <= allowed:
        return False, "unexpected changed attributes: " + ", ".join(sorted(modified - allowed))
    unknown = change.get("after_unknown") or {}
    if not isinstance(unknown, dict) or any(unknown.get(k) for k in modified):
        return False, "unknown planned values"
    for field in modified & {"tags", "tags_all"}:
        tags = after.get(field)
        if tags is not None and (not isinstance(tags, dict) or
                                 any(not isinstance(k, str) or not isinstance(v, str)
                                     for k, v in tags.items())):
            return False, "invalid tags"
    if address in ROLES and "assume_role_policy" in modified and not valid_ecs_trust(after.get("assume_role_policy")):
        return False, "invalid ECS trust policy"
    if address == SECRET and "recovery_window_in_days" in modified and after.get("recovery_window_in_days") != 0:
        return False, "unexpected recovery window"
    # The imported secret must never overwrite an existing replica in another region.
    # This field affects only replication behavior; do not allow enabling it.
    if address == SECRET and "force_overwrite_replica_secret" in modified and after.get("force_overwrite_replica_secret") is not False:
        return False, "replica overwrite must stay disabled"
    return True, ", ".join(sorted(modified))


def main():
    if len(sys.argv) != 3:
        print("Usage: check-baseline-import-update.py plan.json resource", file=sys.stderr)
        return 2
    try:
        plan = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
        ok, reason = check(plan, sys.argv[2])
    except (ValueError, TypeError, OSError) as exc:
        print(f"BLOCKED: invalid plan ({exc.__class__.__name__})", file=sys.stderr)
        return 1
    if not ok:
        print(f"BLOCKED: {sys.argv[2]}: {reason}", file=sys.stderr)
        return 1
    print(f"BASELINE: safe in-place update {sys.argv[2]} ({reason})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
