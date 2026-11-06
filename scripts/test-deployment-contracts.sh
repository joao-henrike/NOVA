#!/usr/bin/env bash
# Purely local, mock-plan tests. No AWS changes.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
guard="$ROOT/scripts/check-application-plan.sh"
make_plan() {
  jq -nc --arg addr "$1" --argjson acts "$2" \
    '{resource_changes:[{mode:"managed",address:$addr,change:{actions:$acts}}]}' > "$tmp/plan.json"
}
pass() { bash "$guard" "$tmp/plan.json" >/dev/null || { echo "Should allow: $1"; exit 1; }; }
fail() { if bash "$guard" "$tmp/plan.json" >/dev/null 2>&1; then echo "Should reject: $1" >&2; exit 1; fi; }
make_plan aws_ecs_task_definition.backend '["delete","create"]'; pass "backend task revision"
make_plan aws_ecs_task_definition.monitoring '["create","delete"]'; pass "monitoring revision"
make_plan aws_ecs_service.backend '["update"]'; pass "service update"
make_plan aws_ecs_service.backend '["delete"]'; fail "service deletion"
make_plan aws_db_instance.this '["update"]'; fail "RDS modification"
make_plan aws_ecs_task_definition.backend '["delete"]'; fail "task deletion"
make_plan aws_iam_role.unknown '["create"]'; fail "unexpected IAM"
printf '{}' > "$tmp/plan.json"; fail "bad plan JSON"
# Partial-state infrastructure baseline reconciliation: allow needed creates,
# the one known ingress update and three retired egress rules only.
baseline_guard="$ROOT/scripts/check-baseline-plan.sh"
baseline_pass() { bash "$baseline_guard" "$tmp/plan.json" >/dev/null || { echo "Baseline should allow: $1" >&2; exit 1; }; }
baseline_fail() { if bash "$baseline_guard" "$tmp/plan.json" >/dev/null 2>&1; then echo "Baseline should reject: $1" >&2; exit 1; fi; }
make_plan aws_db_instance.this '["create"]'; baseline_pass "missing RDS create"
make_plan aws_ecs_cluster.this '["create"]'; baseline_pass "missing ECS cluster create"
make_plan aws_iam_role.ecs_execution '["create"]'; baseline_pass "missing IAM role create"
make_plan 'aws_vpc_security_group_ingress_rule.alb_http[0]' '["update"]'; baseline_pass "legacy ALB ingress description"
for obsolete in frontend_https monitoring_db_all rds_all; do
  make_plan "aws_vpc_security_group_egress_rule.$obsolete" '["delete"]'
  baseline_pass "retire known obsolete security rule $obsolete"
done
make_plan aws_db_instance.this '["delete"]'; baseline_fail "RDS deletion"
make_plan aws_db_instance.this '["delete","create"]'; baseline_fail "RDS replacement"
make_plan 'aws_lb.this[0]' '["delete"]'; baseline_fail "ALB deletion"
make_plan aws_vpc.this '["update"]'; baseline_fail "unreviewed VPC update"
make_plan aws_vpc_security_group_egress_rule.alb_to_frontend '["delete"]'; baseline_fail "unexpected security rule deletion"
make_plan aws_ecs_service.frontend '["update"]'; baseline_fail "existing application service update"

# Imported IAM and Grafana may be normalized, but only exact safe fields.
make_import_update() {
  jq -nc --arg addr "$1" --argjson before "$2" --argjson after "$3" \
    '{resource_changes:[{mode:"managed",address:$addr,change:{actions:["update"],before:$before,after:$after,after_unknown:{}}}]}' \
    > "$tmp/plan.json"
}
for role in ecs_backend_task ecs_execution ecs_frontend_task ecs_monitoring_execution ecs_monitoring_task; do
  make_import_update "aws_iam_role.$role" \
    '{"id":"same","name":"unchanged","tags":{}}' \
    '{"id":"same","name":"unchanged","tags":{"Owner":"cloudstart"}}'
  baseline_pass "imported IAM tags $role"
done
ecs_trust="$(jq -nc '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"sts:AssumeRole",Principal:{Service:"ecs-tasks.amazonaws.com"}}]}')"
jq -nc --arg trust "$ecs_trust" \
  '{resource_changes:[{mode:"managed",address:"aws_iam_role.ecs_execution",change:{actions:["update"],before:{id:"same",assume_role_policy:"{}"},after:{id:"same",assume_role_policy:$trust}}}]}' > "$tmp/plan.json"
baseline_pass "imported IAM ECS-only trust"
make_import_update aws_secretsmanager_secret.grafana_admin \
  '{"id":"same","name":"unchanged","tags":{},"recovery_window_in_days":7}' \
  '{"id":"same","name":"unchanged","tags":{"Owner":"cloudstart"},"recovery_window_in_days":0}'
baseline_pass "imported Grafana secret metadata"
make_import_update aws_iam_role.ecs_execution \
  '{"id":"same","name":"unchanged"}' '{"id":"same","name":"renamed"}'
baseline_fail "IAM role rename"
make_import_update aws_iam_role.ecs_execution \
  '{"id":"same","assume_role_policy":"{}"}' \
  '{"id":"same","assume_role_policy":"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"AWS\":\"*\"}}]}"}'
baseline_fail "IAM broad trust"
make_import_update aws_secretsmanager_secret.grafana_admin \
  '{"id":"same","kms_key_id":"key-a"}' '{"id":"same","kms_key_id":"key-b"}'
baseline_fail "Grafana KMS change"
make_import_update aws_secretsmanager_secret.grafana_admin \
  '{"id":"same","recovery_window_in_days":7}' '{"id":"same","recovery_window_in_days":30}'
baseline_fail "Grafana unreviewed recovery window"
make_plan aws_iam_role.ecs_execution '["delete","create"]'
baseline_fail "IAM replacement"

printf '{}' > "$tmp/plan.json"; baseline_fail "invalid baseline plan"
jq -nc '{resource_changes:[
  {mode:"managed",address:"aws_db_instance.this",change:{actions:["create"]}},
  {mode:"managed",address:"aws_vpc.this",change:{actions:["delete"]}}
]}' > "$tmp/plan.json"
baseline_fail "mixed plan with unsafe deletion"

# Reconciliation must refresh AWS to detect state drift, not trust a nonempty state.
grep -q -- '-refresh=true' "$ROOT/scripts/deploy.sh"
grep -q 'reconcile_baseline' "$ROOT/scripts/deploy.sh"
grep -q "aws_ecs_service" "$ROOT/scripts/deploy.sh"

bash -n "$ROOT/scripts/deploy.sh" "$ROOT/scripts/doctor.sh" \
  "$ROOT/scripts/destroy-all.sh" "$ROOT/scripts/snapshot-rds-before-destroy.sh" \
  "$ROOT/scripts/delete-project-secrets.sh" "$ROOT/scripts/check-baseline-plan.sh"
# Check the fail-closed RDS snapshot helper without AWS credentials.
mkdir -p "$tmp/mock-bin"
cat > "$tmp/mock-bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  *"sts get-caller-identity"*) echo 760396521507 ;;
  *"rds describe-db-instances"*"cloudstart-dev-monitoring-db"*)
    echo "DBInstanceNotFound" >&2; exit 254 ;;
  *"rds describe-db-instances"*"cloudstart-dev-db"*) echo available ;;
  *"rds create-db-snapshot"*)
    if [[ "$MOCK_SNAPSHOT_FAILURE" == 1 ]]; then echo "Simulated snapshot failure" >&2; exit 41; fi ;;
  *"rds wait db-snapshot-available"*) ;;
  *) echo "Unexpected mock action: $*" >&2; exit 90 ;;
esac
MOCK
chmod +x "$tmp/mock-bin/aws"
export AWS_REGION=us-east-1 EXPECTED_AWS_ACCOUNT_ID=760396521507
export MOCK_SNAPSHOT_FAILURE=0
PATH="$tmp/mock-bin:$PATH" bash "$ROOT/scripts/snapshot-rds-before-destroy.sh" > "$tmp/snapshots.out"
grep -q '^PRESERVED_SNAPSHOT=cloudstart-dev-db-pre-destroy-' "$tmp/snapshots.out"
export MOCK_SNAPSHOT_FAILURE=1
if PATH="$tmp/mock-bin:$PATH" bash "$ROOT/scripts/snapshot-rds-before-destroy.sh" > "$tmp/snapshots.err" 2>&1; then
  echo "Snapshot failure did not block deletion." >&2; exit 1
fi

echo "Deploy and teardown contract tests passed."
