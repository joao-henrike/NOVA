#!/usr/bin/env bash
# Guard the second deployment plan. Terraform replaces ECS task definitions
# (create+delete) when publishing a new immutable revision.
set -Eeuo pipefail
[[ $# -eq 1 && -r "$1" ]] || { echo "Usage: $0 plan.json" >&2; exit 2; }
plan="$1"
jq -e '.resource_changes | type == "array"' "$plan" >/dev/null ||
  { echo "Invalid Terraform plan JSON." >&2; exit 1; }
allowed='^aws_(ecs_task_definition\.(frontend|backend|db_bootstrap|db_migration|monitoring)|ecs_service\.(frontend|backend|monitoring)|appautoscaling_target\.(frontend|backend)|iam_role\.(ecs_backend_execution|ecs_migration_execution|ecs_db_bootstrap_execution)|iam_role_policy\.(ecs_execution|ecs_backend_execution|ecs_migration_execution|ecs_db_bootstrap_execution|ecs_monitoring_execution|ecs_monitoring_metrics)|security_group\.database_tasks|vpc_security_group_egress_rule\.(frontend_ecr_https|database_tasks_https|database_tasks_to_rds)|vpc_security_group_ingress_rule\.rds_from_database_tasks|cloudwatch_log_group\.(frontend|backend|db_bootstrap|db_migration|monitoring))$'
task_def='^aws_ecs_task_definition\.(frontend|backend|db_bootstrap|db_migration|monitoring)$'
bad=0
while IFS=$'\t' read -r address actions; do
  [[ -n "$address" ]] || continue
  if ! [[ "$address" =~ $allowed ]]; then
    printf 'BLOCKED: out-of-scope %s (%s)\n' "$address" "$actions" >&2
    bad=1
  elif [[ ",$actions," == *,delete,* ]]; then
    if [[ "$address" =~ $task_def && ( "$actions" == "create,delete" || "$actions" == "delete,create" ) ]]; then
      printf 'ALLOWED: ECS task-definition revision %s\n' "$address"
    else
      printf 'BLOCKED: destructive change %s (%s)\n' "$address" "$actions" >&2
      bad=1
    fi
  fi
done < <(jq -r '.resource_changes[] | select(.mode == "managed") | select(.change.actions != ["no-op"]) | [.address, (.change.actions | join(","))] | @tsv' "$plan")
[[ "$bad" == 0 ]] || exit 1
echo "Application delivery plan guard passed."
