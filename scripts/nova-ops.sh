#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="$ROOT_DIR/config/dev.tfvars"
ENVFILE="$ROOT_DIR/config/dev.env"
read_value() {
  local file="$1" key="$2" fallback="$3" value=""
  [[ -f "$file" ]] && value="$(awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); gsub(/^"|"$/,""); print; exit}' "$file")"
  printf '%s' "${value:-$fallback}"
}
PROJECT="$(read_value "$TFVARS" project_name cloudstart)"
ENVIRONMENT="$(read_value "$TFVARS" environment dev)"
REGION="$(read_value "$ENVFILE" AWS_REGION us-east-1)"
EXPECTED_ACCOUNT="$(read_value "$ENVFILE" EXPECTED_AWS_ACCOUNT_ID 760396521507)"
CLUSTER="${PROJECT}-${ENVIRONMENT}-cluster"
require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
preflight() {
  require aws
  local current
  current="$(aws sts get-caller-identity --query Account --output text --region "$REGION")"
  [[ "$current" == "$EXPECTED_ACCOUNT" ]] || { echo "Wrong AWS account: expected $EXPECTED_ACCOUNT, got $current" >&2; exit 1; }
  printf 'AWS account %s | %s | %s/%s\n' "$current" "$REGION" "$PROJECT" "$ENVIRONMENT"
}
help() {
  cat <<'EOF'
NOVA Ops commands:
  make ops                           Interactive menu
  make ops ACTION=overview           ECS, RDS, NAT, ALB, tagged resources
  make ops ACTION=services           ECS service state and autoscaling
  make ops ACTION=inventory          Resource inventory by Project/Environment tags
  make ops ACTION=costs              Month-to-date account costs by AWS service
  make ops ACTION=logs ARGS='backend --since 2h'
  make ops ACTION=scale ARGS='frontend 1'
  make ops ACTION=stop ARGS='application|frontend|backend|monitoring'
  make ops ACTION=start ARGS='application|frontend|backend|monitoring'
  make ops ACTION=db ARGS='status|stop application|start application'
  make ops ACTION=restart ARGS='frontend|backend|monitoring'
EOF
}
services() {
  aws ecs describe-services --cluster "$CLUSTER" --services "${PROJECT}-${ENVIRONMENT}-frontend" "${PROJECT}-${ENVIRONMENT}-backend" "${PROJECT}-${ENVIRONMENT}-monitoring" --query 'services[].{Name:serviceName,Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount}' --output table --region "$REGION"
  aws application-autoscaling describe-scalable-targets --service-namespace ecs --query 'ScalableTargets[].{Resource:ResourceId,Min:MinCapacity,Max:MaxCapacity,Suspended:suspendedState}' --output table --region "$REGION"
}
database_status() {
  aws rds describe-db-instances --region "$REGION" --query "DBInstances[?contains(DBInstanceIdentifier, '${PROJECT}-${ENVIRONMENT}')].{Name:DBInstanceIdentifier,Status:DBInstanceStatus,Class:DBInstanceClass,StorageGiB:AllocatedStorage,MultiAZ:MultiAZ}" --output table
}
overview() {
  services
  database_status
  aws ec2 describe-nat-gateways --filter "Name=tag:Project,Values=$PROJECT" "Name=tag:Environment,Values=$ENVIRONMENT" --query 'NatGateways[].{ID:NatGatewayId,State:State,PublicIP:NatGatewayAddresses[0].PublicIp}' --output table --region "$REGION"
  aws elbv2 describe-load-balancers --names "${PROJECT}-${ENVIRONMENT}-alb" --query 'LoadBalancers[].{Name:LoadBalancerName,State:State.Code,DNS:DNSName}' --output table --region "$REGION"
  inventory_count
}
inventory_count() {
  aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=$PROJECT" "Key=Environment,Values=$ENVIRONMENT" --query 'length(ResourceTagMappingList)' --output text --region "$REGION"
}
inventory() {
  require jq
  aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=$PROJECT" "Key=Environment,Values=$ENVIRONMENT" --output json --region "$REGION | jq -r '.ResourceTagMappingList[]? | [.ResourceARN, ((.Tags // []) | map(.Key+"="+.Value) | join(","))] | @tsv'
}
costs() {
  require jq
  local start end
  start="$(date -u +%Y-%m-01)"
  end="$(date -u -d tomorrow +%Y-%m-%d)"
  aws ce get-cost-and-usage --time-period "Start=$start,End=$end" --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE --region us-east-1 --output json | jq -r '.ResultsByTime[0] as $p | "TOTAL\t\($p.Total.UnblendedCost.Amount // "0")", (($p.Groups // []) | sort_by((.Metrics.UnblendedCost.Amount // "0")|tonumber) | reverse[] | "\(.Keys[0])\t\(.Metrics.UnblendedCost.Amount)")'
  echo 'Cost Explorer totals are account-wide, not NOVA-only.'
}
logs() {
  local target="${1:-}" since="1h"
  shift || true
  while (($#)); do
    case "$1" in --since) since="$2"; shift 2;; *) echo "Unknown logs option: $1" >&2; exit 1;; esac
  done
  [[ "$since" =~ ^[0-9]+(s|m|h|d)$ ]] || { echo 'Use --since 30m|2h|1d' >&2; exit 1; }
  local group
  case "$target" in
    frontend|backend|monitoring|db-bootstrap|db-migration) group="/ecs/${PROJECT}-${ENVIRONMENT}/$target";;
    *) echo 'Unknown log group' >&2; exit 1;;
  esac
  aws logs tail "$group" --since "$since" --format short --region "$REGION"
}
