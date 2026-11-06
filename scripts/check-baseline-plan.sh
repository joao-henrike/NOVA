#!/usr/bin/env bash
# Fail-closed guard for initial/partial Terraform baseline reconciliation.
# This plan is only applied when no ECS application service is recorded in state.
set -Eeuo pipefail
[[ $# -eq 1 && -r "$1" ]] || { echo "Usage: $0 plan.json" >&2; exit 2; }
plan="$1"

jq -e '(.resource_changes | type == "array") and
  all(.resource_changes[]; (.address | type == "string") and
    (.change.actions | type == "array"))' "$plan" >/dev/null ||
  { echo "Invalid Terraform baseline plan JSON." >&2; exit 1; }

# Only these three former outbound rules are absent from the current Terraform
# configuration and may be removed while completing the partial baseline.
retired_egress='^aws_vpc_security_group_egress_rule\.(frontend_https|monitoring_db_all|rds_all)$'
# Observed legacy ALB ingress description change; do not allow arbitrary updates.
allowed_update='^aws_vpc_security_group_ingress_rule\.alb_http\[0\]
blocked=0

while IFS=$'\t' read -r address actions; do
  [[ -n "$address" ]] || continue
  case "$actions" in
    create)
      printf 'BASELINE: create %s\n' "$address"
      ;;
    update)
      if [[ "$address" =~ $allowed_update ]]; then
        printf 'BASELINE: allowed ALB ingress update %s\n' "$address"
      elif [[ "$address" =~ $imported_role || "$address" == "$imported_secret" ]]; then
        if python3 "$ROOT_DIR/scripts/check-baseline-import-update.py" "$plan" "$address"; then
          :
        else
          printf 'BLOCKED: imported resource update %s\n' "$address" >&2
          blocked=1
        fi
      else
        printf 'BLOCKED: unexpected baseline update %s\n' "$address" >&2
        blocked=1
      fi
      ;;
    delete)
      if [[ "$address" =~ $retired_egress ]]; then
        printf 'BASELINE: retire obsolete outbound rule %s\n' "$address"
      else
        printf 'BLOCKED: unexpected baseline deletion %s\n' "$address" >&2
        blocked=1
      fi
      ;;
    *)
      printf 'BLOCKED: unsupported baseline action %s (%s)\n' "$address" "$actions" >&2
      blocked=1
      ;;
  esac
done < <(jq -r '.resource_changes[] |
  select(.mode == "managed") |
  select(.change.actions != ["no-op"]) |
  [.address, (.change.actions | join(","))] | @tsv' "$plan")
[[ "$blocked" -eq 0 ]] || exit 1
echo "Infrastructure baseline plan guard passed."

# Guarded reconciliation of pre-existing IAM roles and Grafana secret.
# Only metadata / an exactly-scoped ECS trust document may change.
imported_role='^aws_iam_role\.(ecs_backend_task|ecs_execution|ecs_frontend_task|ecs_monitoring_execution|ecs_monitoring_task)
blocked=0

while IFS=$'\t' read -r address actions; do
  [[ -n "$address" ]] || continue
  case "$actions" in
    create)
      printf 'BASELINE: create %s\n' "$address"
      ;;
    update)
      if [[ "$address" =~ $allowed_update ]]; then
        printf 'BASELINE: allowed ALB ingress update %s\n' "$address"
      else
        printf 'BLOCKED: unexpected baseline update %s\n' "$address" >&2
        blocked=1
      fi
      ;;
    delete)
      if [[ "$address" =~ $retired_egress ]]; then
        printf 'BASELINE: retire obsolete outbound rule %s\n' "$address"
      else
        printf 'BLOCKED: unexpected baseline deletion %s\n' "$address" >&2
        blocked=1
      fi
      ;;
    *)
      printf 'BLOCKED: unsupported baseline action %s (%s)\n' "$address" "$actions" >&2
      blocked=1
      ;;
  esac
done < <(jq -r '.resource_changes[] |
  select(.mode == "managed") |
  select(.change.actions != ["no-op"]) |
  [.address, (.change.actions | join(","))] | @tsv' "$plan")
[[ "$blocked" -eq 0 ]] || exit 1
echo "Infrastructure baseline plan guard passed."

imported_secret='aws_secretsmanager_secret.grafana_admin'
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
blocked=0

while IFS=$'\t' read -r address actions; do
  [[ -n "$address" ]] || continue
  case "$actions" in
    create)
      printf 'BASELINE: create %s\n' "$address"
      ;;
    update)
      if [[ "$address" =~ $allowed_update ]]; then
        printf 'BASELINE: allowed ALB ingress update %s\n' "$address"
      else
        printf 'BLOCKED: unexpected baseline update %s\n' "$address" >&2
        blocked=1
      fi
      ;;
    delete)
      if [[ "$address" =~ $retired_egress ]]; then
        printf 'BASELINE: retire obsolete outbound rule %s\n' "$address"
      else
        printf 'BLOCKED: unexpected baseline deletion %s\n' "$address" >&2
        blocked=1
      fi
      ;;
    *)
      printf 'BLOCKED: unsupported baseline action %s (%s)\n' "$address" "$actions" >&2
      blocked=1
      ;;
  esac
done < <(jq -r '.resource_changes[] |
  select(.mode == "managed") |
  select(.change.actions != ["no-op"]) |
  [.address, (.change.actions | join(","))] | @tsv' "$plan")
[[ "$blocked" -eq 0 ]] || exit 1
echo "Infrastructure baseline plan guard passed."
