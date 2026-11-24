#!/usr/bin/env bash
# Guard the second deployment plan. Permit only reviewed changes.
set -Eeuo pipefail
[[ $# -eq 1 && -r "$1" ]] || { echo "Usage: $0 plan.json" >&2; exit 2; }
plan="$1"
jq -e '(.resource_changes | type == "array") and
  all(.resource_changes[]; (.address | type == "string") and (.change.actions | type == "array"))' "$plan" >/dev/null ||
  { echo "Invalid Terraform plan JSON." >&2; exit 1; }
allowed='^aws_(ecs_task_definition\.(frontend|backend|db_bootstrap|db_migration|monitoring)|ecs_service\.(frontend|backend|monitoring)|appautoscaling_target\.(frontend|backend)|iam_role\.(ecs_backend_execution|ecs_migration_execution|ecs_db_bootstrap_execution)|iam_role_policy\.(ecs_execution|ecs_backend_execution|ecs_migration_execution|ecs_db_bootstrap_execution|ecs_monitoring_execution|ecs_monitoring_metrics)|security_group\.database_tasks|vpc_security_group_egress_rule\.(frontend_ecr_https|database_tasks_https|database_tasks_to_rds)|vpc_security_group_ingress_rule\.rds_from_database_tasks|cloudwatch_log_group\.(frontend|backend|db_bootstrap|db_migration|monitoring))$'
task_def='^aws_ecs_task_definition\.(frontend|backend|db_bootstrap|db_migration|monitoring)$'
monitoring_create='^(terraform_data\.grafana_storage_keys|aws_s3_(bucket|bucket_public_access_block|bucket_server_side_encryption_configuration|bucket_versioning|bucket_lifecycle_configuration)\.monitoring_assets|aws_s3_object\.monitoring_dashboards|aws_kms_key\.monitoring_task_events|aws_cloudwatch_log_group\.monitoring_task_events|aws_cloudwatch_(event_rule|event_target)\.monitoring_task_stopped|aws_cloudwatch_log_resource_policy\.monitoring_task_events|aws_cloudwatch_metric_alarm\.(grafana_no_healthy_target|monitoring_alb_503)\[0\])$'
monitoring_update='^aws_(s3_object\.monitoring_dashboards|cloudwatch_metric_alarm\.(grafana_no_healthy_target|monitoring_alb_503)\[0\])$'
retention_only() {
  jq -e 'any(.resource_changes[];
    .address == "aws_db_instance.monitoring" and
    .change.actions == ["update"] and
    (.change.before | type) == "object" and (.change.after | type) == "object" and
    (.change.before.backup_retention_period | type) == "number" and
    .change.after.backup_retention_period == 7 and
    .change.before.backup_retention_period < 7 and
    (.change as $c |
      (($c.before | del(.backup_retention_period)) | to_entries |
       map(select(($c.after_unknown[.key] // false) != true)) | from_entries) ==
      (($c.after | del(.backup_retention_period)) | to_entries |
       map(select(($c.after_unknown[.key] // false) != true)) | from_entries)
    ))' "$plan" >/dev/null
}
same_grafana_secret() {
  jq -e 'any(.resource_changes[];
    .address == "aws_secretsmanager_secret_version.grafana_admin" and
    (.change.before.secret_id | type) == "string" and
    .change.before.secret_id == .change.after.secret_id)' "$plan" >/dev/null
}
bad=0
while IFS=$'\t' read -r address actions; do
  [[ -n "$address" ]] || continue
  if [[ "$address" =~ $monitoring_create && "$actions" == "create" ]]; then
    printf 'ALLOWED: reviewed monitoring resource %s\n' "$address"
  elif [[ "$address" =~ $monitoring_update && "$actions" == "update" ]]; then
    printf 'ALLOWED: monitoring configuration update %s\n' "$address"
  elif [[ "$address" == "aws_db_instance.monitoring" && "$actions" == "update" ]] && retention_only; then
    printf 'ALLOWED: monitoring backup retention increase\n'
  elif [[ "$address" == "aws_secretsmanager_secret_version.grafana_admin" ]] &&
       { [[ "$actions" == "create" ]] ||
         { [[ "$actions" == "create,delete" || "$actions" == "delete,create" ]] && same_grafana_secret; }; }; then
    printf 'ALLOWED: Grafana credential version (secret resource preserved)\n'
  elif ! [[ "$address" =~ $allowed ]]; then
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
