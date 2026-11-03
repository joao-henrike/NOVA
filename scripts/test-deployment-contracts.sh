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
bash -n "$ROOT/scripts/deploy.sh" "$ROOT/scripts/doctor.sh" \
  "$ROOT/scripts/destroy-all.sh" "$ROOT/scripts/snapshot-rds-before-destroy.sh" \
  "$ROOT/scripts/delete-project-secrets.sh"
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
