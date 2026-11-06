#!/usr/bin/env python3
"""One-time NOVA 2026-11-06 legacy AWS Terraform state recovery.

Run in the AWS CloudShell from the existing ~/NOVA checkout. Assumes the
confirmed recovery identifiers, and refuses execution if anything drifts.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path.home() / "NOVA"
ACCOUNT, REGION = "760396521507", "us-east-1"
BUCKET = f"cloudstart-nova-terraform-state-{ACCOUNT}"
CANON, OLD, OTHER = (
    "cloudstart/dev/terraform.tfstate",
    "cloudstart/terraform.tfstate",
    "cloudstart/redeploy-2026-10-08/terraform.tfstate",
)
MAIN_VPC, OLD_VPC = "vpc-02e700222521a3c71", "vpc-060907935831aae05"
ALB = f"arn:aws:elasticloadbalancing:{REGION}:{ACCOUNT}:loadbalancer/app/cloudstart-dev-alb/f572dfce85b65409"
CLUSTER = f"arn:aws:ecs:{REGION}:{ACCOUNT}:cluster/cloudstart-dev-cluster"
SECRET_NAME = "cloudstart-dev/monitoring/grafana-admin"
SECRET = f"arn:aws:secretsmanager:{REGION}:{ACCOUNT}:secret:{SECRET_NAME}-mLJBqh"
LINEAGES = {
    CANON: "99e83983-c2d4-08cb-5a64-69c27183bf5a",
    OLD: "f06bc9cb-6d1d-1ccf-85ac-22d34ed4db97",
    OTHER: "eb0a322f-ab54-6fca-dd81-2e7c65b3cca3",
}
ROLES = {
    "ecs_backend_task": ("cloudstart-dev-ecs-backend-task", "AROA3CCZKEARUYBJ5HXO4"),
    "ecs_execution": ("cloudstart-dev-ecs-execution", "AROA3CCZKEAR7UI5R4RM2"),
    "ecs_frontend_task": ("cloudstart-dev-ecs-frontend-task", "AROA3CCZKEAR4HBVU5FZS"),
    "ecs_monitoring_execution": ("cloudstart-dev-ecs-monitoring-execution", "AROA3CCZKEARX7LJ4XZ7R"),
    "ecs_monitoring_task": ("cloudstart-dev-ecs-monitoring-task", "AROA3CCZKEAR2L43465TD"),
}
TARGET_GROUPS = {
    "backend": f"arn:aws:elasticloadbalancing:{REGION}:{ACCOUNT}:targetgroup/cloudstart-dev-backend-tg/89e529d59173a0df",
    "frontend": f"arn:aws:elasticloadbalancing:{REGION}:{ACCOUNT}:targetgroup/cloudstart-dev-frontend-tg/6849a62d8879df55",
    "grafana": f"arn:aws:elasticloadbalancing:{REGION}:{ACCOUNT}:targetgroup/cloudstart-dev-grafana-tg/f1fa6a35f561cfe1",
}
SUBNET_GROUPS = {
    "this": "cloudstart-dev-db-subnets",
    "monitoring": "cloudstart-dev-monitoring-db-subnets",
}
STALE_DB_IDS = {"this": "db-Y7T4TTCTAKOI2VOBS62FTOXF5M", "monitoring": "db-XWPBPF7IRVTLKOIRDHRDMRCHLQ"}
SNAPSHOTS = ("cloudstart-dev-db-snapshot", "cloudstart-dev-monitoring-db-snapshot")

class Stop(Exception):
    pass

def cmd(argv, *, env=None):
    p = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True)
    if p.returncode:
        # stdout may contain sensitive Terraform state or AWS secret material.
        raise Stop(f"{argv[0]} {argv[1] if len(argv)>1 else ''}: {p.stderr.strip()[:800]}")
    return p.stdout

def aws(*args, missing=()):
    p = subprocess.run(["aws", *args, "--region", REGION, "--output", "json", "--no-cli-pager"],
                       cwd=ROOT, text=True, capture_output=True)
    if p.returncode:
        if any(error in p.stderr for error in missing):
            return None
        raise Stop(f"AWS {args[0]} {args[1]}: {p.stderr.strip()[:800]}")
    return json.loads(p.stdout) if p.stdout.strip() else {}

def state_id(state, address):
    matching = [i for r in state.get("resources", [])
                if r.get("mode") == "managed" and not r.get("module")
                and f"{r.get('type')}.{r.get('name')}" == address
                for i in r.get("instances", [])]
    if len(matching) > 1:
        raise Stop(f"Unexpected multiple instances: {address}")
    return str(matching[0].get("attributes", {}).get("id", "")) if matching else None

def cli_address(addresses, addr):
    result = [x for x in addresses if x == addr or x == f"{addr}[0]"]
    if len(result) > 1:
        raise Stop(f"Multiple Terraform addresses: {addr}")
    return result[0] if result else None

def expected_state(states):
    for key in (CANON, OLD, OTHER):
        if states[key].get("lineage") != LINEAGES[key]:
            raise Stop(f"State lineage has changed: {key}")
    canonical = {
        "aws_vpc.this": MAIN_VPC, "aws_lb.this": ALB,
        "aws_ecs_cluster.this": CLUSTER,
        "aws_ecr_repository.frontend": "cloudstart-dev-frontend",
        "aws_ecr_repository.backend": "cloudstart-dev-backend",
    }
    legacy = {
        **{k: v for k, v in canonical.items() if k != "aws_vpc.this" and k != "aws_lb.this"},
        "aws_lb.this": ALB.replace("f572dfce85b65409", "19c3a250f50fd607"),
        "aws_secretsmanager_secret.grafana_admin": SECRET,
        **{f"aws_iam_role.{k}": v[0] for k, v in ROLES.items()},
        **{f"aws_lb_target_group.{k}": v for k, v in TARGET_GROUPS.items()},
        **{f"aws_db_subnet_group.{k}": v for k, v in SUBNET_GROUPS.items()},
        **{f"aws_db_instance.{k}": v for k, v in STALE_DB_IDS.items()},
    }
    for address, value in canonical.items():
        if state_id(states[CANON], address) != value:
            raise Stop(f"Canonical resource changed: {address}")
    for address, value in legacy.items():
        old_value = state_id(states[OLD], address)
        if old_value is not None and old_value != value:
            raise Stop(f"Legacy identity changed: {address}")
        if state_id(states[OTHER], address) is not None:
            raise Stop(f"Third State also tracks resource: {address}")
    imported = {**{f"aws_iam_role.{k}": v[0] for k,v in ROLES.items()},
                "aws_secretsmanager_secret.grafana_admin": SECRET}
    for address, value in imported.items():
        current = state_id(states[CANON], address)
        if current is not None and current != value:
            raise Stop(f"Canonical imported identity has changed: {address}")

def live_preflight():
    account = aws("sts", "get-caller-identity")["Account"]
    if str(account) != ACCOUNT:
        raise Stop("Wrong AWS account")
    alb = aws("elbv2", "describe-load-balancers", "--names", "cloudstart-dev-alb")["LoadBalancers"]
    if len(alb) != 1 or alb[0]["LoadBalancerArn"] != ALB or alb[0]["VpcId"] != MAIN_VPC:
        raise Stop("Canonical ALB was changed")
    cluster = aws("ecs", "describe-clusters", "--clusters", "cloudstart-dev-cluster")["clusters"]
    if len(cluster) != 1 or cluster[0]["clusterArn"] != CLUSTER or cluster[0]["status"] != "ACTIVE":
        raise Stop("ECS cluster was changed")
    if aws("ecs", "list-services", "--cluster", "cloudstart-dev-cluster")["serviceArns"]:
        raise Stop("ECS services are running; do not perform recovery")
    if aws("ecs", "list-tasks", "--cluster", "cloudstart-dev-cluster")["taskArns"]:
        raise Stop("ECS tasks are running; do not perform recovery")
    repos = aws("ecr", "describe-repositories", "--repository-names",
                "cloudstart-dev-frontend", "cloudstart-dev-backend")["repositories"]
    if sorted(x["repositoryName"] for x in repos) != ["cloudstart-dev-backend", "cloudstart-dev-frontend"]:
        raise Stop("ECR repositories have changed")
    for key, (name, role_id) in ROLES.items():
        role = aws("iam", "get-role", "--role-name", name)["Role"]
        if role["RoleName"] != name or role["RoleId"] != role_id:
            raise Stop(f"IAM role identity changed: {key}")
    detail = aws("secretsmanager", "describe-secret", "--secret-id", SECRET_NAME)
    if detail["ARN"] != SECRET or detail.get("DeletedDate"):
        raise Stop("Grafana secret was changed/deleted")
    try:
        existing_password = json.loads(aws("secretsmanager", "get-secret-value",
                                           "--secret-id", SECRET_NAME)["SecretString"])["password"]
    except (TypeError, ValueError, KeyError) as error:
        raise Stop("Existing Grafana password cannot be preserved") from error
    if not isinstance(existing_password, str) or len(existing_password) < 12 or "\n" in existing_password:
        raise Stop("Grafana password invalid; refusing to rotate")
    dbs = aws("rds", "describe-db-instances")["DBInstances"]
    if any(d["DBInstanceIdentifier"] in ("cloudstart-dev-db", "cloudstart-dev-monitoring-db")
           or (d.get("DBSubnetGroup") or {}).get("DBSubnetGroupName") in SUBNET_GROUPS.values()
           for d in dbs):
        raise Stop("RDS instance still depends on legacy subnet group")
    if aws("rds", "describe-db-clusters")["DBClusters"]:
        raise Stop("RDS cluster exists; aborting removal")
    for name in SNAPSHOTS:
        snaps = aws("rds", "describe-db-snapshots", "--db-snapshot-identifier", name)["DBSnapshots"]
        if len(snaps) != 1 or snaps[0]["Status"] != "available":
            raise Stop(f"Snapshot unavailable: {name}")
    for kind, arn in TARGET_GROUPS.items():
        name = f"cloudstart-dev-{kind}-tg"
        response = aws("elbv2", "describe-target-groups", "--names", name,
                       missing=("TargetGroupNotFound",))
        if response is None:
            continue  # Supports rerunning after a partially completed cleanup.
        tg = response["TargetGroups"]
        if len(tg) != 1 or tg[0]["TargetGroupArn"] != arn or tg[0]["VpcId"] != OLD_VPC or tg[0]["LoadBalancerArns"]:
            raise Stop(f"Target group must be preserved: {name}")
        targets = aws("elbv2", "describe-target-health", "--target-group-arn", arn)
        if targets["TargetHealthDescriptions"]:
            raise Stop(f"Target group has registered targets: {name}")
    for name in SUBNET_GROUPS.values():
        response = aws("rds", "describe-db-subnet-groups", "--db-subnet-group-name", name,
                       missing=("DBSubnetGroupNotFound",))
        if response and (len(response["DBSubnetGroups"]) != 1 or
                         response["DBSubnetGroups"][0]["VpcId"] != OLD_VPC):
            raise Stop(f"Subnet group must be preserved: {name}")
    return existing_password

def tf(env, *args):
    binary = ROOT / ".tools/bin/terraform"
    if not binary.is_file():
        raise Stop("Terraform missing; first run make setup")
    return cmd([str(binary), *args], env=env)

def initialize(env, key):
    tf(env, "init", "-reconfigure", "-input=false", "-no-color",
       f"-backend-config=bucket={BUCKET}", f"-backend-config=region={REGION}",
       f"-backend-config=key={key}")

def migrate(old_env, canon_env):
    names = ["aws_ecr_repository.frontend", "aws_ecr_repository.backend",
             "aws_ecs_cluster.this", "aws_lb.this",
             *(f"aws_iam_role.{key}" for key in ROLES),
             "aws_secretsmanager_secret.grafana_admin",
             *(f"aws_lb_target_group.{key}" for key in TARGET_GROUPS),
             *(f"aws_db_subnet_group.{key}" for key in SUBNET_GROUPS),
             *(f"aws_db_instance.{key}" for key in STALE_DB_IDS)]
    old_addresses = set(tf(old_env, "state", "list").splitlines())
    remove = [address for name in names if (address := cli_address(old_addresses, name))]
    if remove:
        print(f"Removing {len(remove)} bindings from legacy State (does not destroy AWS resources).", flush=True)
        tf(old_env, "state", "rm", "-lock-timeout=5m", *remove)
    imports = [(f"aws_iam_role.{k}", data[0]) for k, data in ROLES.items()]
    imports.append(("aws_secretsmanager_secret.grafana_admin", SECRET))
    for address, resource_id in imports:
        canon_addresses = set(tf(canon_env, "state", "list").splitlines())
        if cli_address(canon_addresses, address):
            continue  # Already imported in an earlier partial run.
        print(f"Import existing: {address}", flush=True)
        tf(canon_env, "import", "-input=false", "-lock-timeout=5m",
           "-var-file=config/dev.tfvars", address, resource_id)
    for kind, arn in TARGET_GROUPS.items():
        result = aws("elbv2", "describe-target-groups", "--names", f"cloudstart-dev-{kind}-tg",
                     missing=("TargetGroupNotFound",))
        if result:
            print(f"Deleting unused target group in old VPC: {kind}", flush=True)
            aws("elbv2", "delete-target-group", "--target-group-arn", arn)
    for name in SUBNET_GROUPS.values():
        result = aws("rds", "describe-db-subnet-groups", "--db-subnet-group-name", name,
                     missing=("DBSubnetGroupNotFound",))
        if result:
            print(f"Deleting unused DB subnet group in old VPC: {name}", flush=True)
            aws("rds", "delete-db-subnet-group", "--db-subnet-group-name", name)

def main():
    os.umask(0o077)
    config = ROOT / "config/dev.env"
    if not config.is_file():
        raise Stop("NOVA checkout not found under ~/NOVA")
    settings = dict(m.groups() for line in config.read_text().splitlines()
                    if (m := re.fullmatch(r"([A-Z_]+)=(.*)", line.strip())))
    if (settings.get("AWS_REGION"), settings.get("EXPECTED_AWS_ACCOUNT_ID"),
        settings.get("TF_STATE_BUCKET"), settings.get("TF_STATE_KEY")) != (REGION, ACCOUNT, BUCKET, CANON):
        raise Stop("NOVA dev configuration changed; refusing recovery")
    if set(settings.get("LEGACY_TF_STATE_KEYS", "").split(",")) != {OLD, OTHER}:
        raise Stop("Legacy State key configuration changed")
    if cmd(["git", "branch", "--show-current"]).strip() != "main":
        raise Stop("Switch to NOVA main")
    if cmd(["git", "status", "--porcelain"]).strip():
        raise Stop("Working tree is not clean")
    if os.environ.get("AWS_REGION") and os.environ["AWS_REGION"] != REGION:
        raise Stop("AWS_REGION differs from approved recovery")
    if str(aws("sts", "get-caller-identity")["Account"]) != ACCOUNT:
        raise Stop("Wrong AWS account")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder = ROOT / ".deploy" / f"state-recovery-{stamp}"
    folder.mkdir(parents=True, mode=0o700)
    states = {}
    for key in (CANON, OLD, OTHER):
        target = folder / (key.replace("/", "_") + ".json")
        cmd(["aws", "s3api", "get-object", "--bucket", BUCKET, "--key", key,
             "--expected-bucket-owner", ACCOUNT, "--region", REGION,
             "--no-cli-pager", str(target)])
        target.chmod(0o600)
        content = target.read_bytes()
        states[key] = json.loads(content)
        print(f"Backup protected: {key} SHA256={hashlib.sha256(content).hexdigest()[:12]}...", flush=True)
    expected_state(states)
    password = live_preflight()
    print("PASS: recorded inventory matches canonical and legacy AWS resources.", flush=True)
    print("This changes two Terraform States and deletes only five empty old-VPC objects.", flush=True)
    phrase = f"RECONCILE NOVA {ACCOUNT} {REGION}"
    if input(f"Type exactly '{phrase}' to proceed: ").strip() != phrase:
        raise Stop("Confirmation declined; no changes made")

    # Existing secret remains unchanged. Avoid rotating the password on make deploy.
    secret_folder = ROOT / ".deploy"
    secret_folder.mkdir(exist_ok=True, mode=0o700)
    secret_file = secret_folder / "grafana-admin-password"
    if secret_file.exists() and secret_file.read_text() != password:
        archived = secret_folder / f"grafana-admin-password.previous-{stamp}"
        archived.write_bytes(secret_file.read_bytes())
        archived.chmod(0o600)
    temporary = secret_folder / "grafana-admin-password.recovery-tmp"
    temporary.write_text(password)
    temporary.chmod(0o600)
    temporary.replace(secret_file)

    workspace = Path("/tmp") / f"nova-state-recovery-{stamp}"
    workspace.mkdir(mode=0o700)
    cache = workspace / "plugin-cache"
    cache.mkdir(mode=0o700)
    terraformrc = workspace / "terraformrc"
    terraformrc.write_text(f'plugin_cache_dir = "{cache}"\n')
    terraformrc.chmod(0o600)
    def environment(data_dir):
        env = os.environ.copy()
        env.update(TF_DATA_DIR=str(workspace / data_dir), TF_PLUGIN_CACHE_DIR=str(cache),
                   TF_CLI_CONFIG_FILE=str(terraformrc), TF_INPUT="false")
        return env
    old_env = environment("tf-legacy")
    canon_env = environment("tf-canonical")
    print("Initializing both remote Terraform State backends...", flush=True)
    initialize(old_env, OLD)
    initialize(canon_env, CANON)
    expected_state({CANON: json.loads(tf(canon_env, "state", "pull")),
                    OLD: json.loads(tf(old_env, "state", "pull")),
                    OTHER: states[OTHER]})
    migrate(old_env, canon_env)
    env = os.environ.copy()
    env.update(settings)
    print(cmd([sys.executable, str(ROOT / "scripts/check-cloud-state-ownership.py")], env=env).strip())
    print("RECOVERY PASS. Run make deploy. Existing RDS snapshots were preserved.", flush=True)
    print("Protected backups:", folder, flush=True)

if __name__ == "__main__":
    try:
        main()
    except (Stop, KeyError, ValueError, OSError, json.JSONDecodeError) as error:
        print(f"STOP: {error}", file=sys.stderr)
        print("Do not bypass Terraform protection or delete canonical resources.", file=sys.stderr)
        sys.exit(1)
