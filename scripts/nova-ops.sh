#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="$ROOT_DIR/config/dev.tfvars"
ENVFILE="$ROOT_DIR/config/dev.env"
read_value() {
  local file="$1" key="$2" fallback="$3" value=""
  if [[ "$file" == *.tfvars ]]; then
    value="$(awk -v k="$key" '$1==k && $2=="=" { $1=""; $2=""; sub(/^[[:space:]]+/,""); gsub(/^"|"$/,""); print; exit }' "$file")"
  elif [[ -f "$file" ]]; then
    value="$(awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/,""); print; exit }' "$file")"
  fi
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
  aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=$PROJECT" "Key=Environment,Values=$ENVIRONMENT" --output json --region "$REGION" | jq -r '.ResourceTagMappingList[]? | [.ResourceARN, ((.Tags // []) | map(.Key+"="+.Value) | join(","))] | @tsv'
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

service_id() {
  case "$1" in
    frontend) printf '%s' "${PROJECT}-${ENVIRONMENT}-frontend" ;;
    backend) printf '%s' "${PROJECT}-${ENVIRONMENT}-backend" ;;
    monitoring) printf '%s' "${PROJECT}-${ENVIRONMENT}-monitoring" ;;
    *) echo "Unknown service: $1" >&2; exit 1 ;;
  esac
}
desired_count() {
  aws ecs describe-services --cluster "$CLUSTER" --services "$1" --query 'services[0].desiredCount' --output text --region "$REGION"
}
db_identifier() {
  case "$1" in
    application) printf '%s' "${PROJECT}-${ENVIRONMENT}-db" ;;
    monitoring) printf '%s' "${PROJECT}-${ENVIRONMENT}-monitoring-db" ;;
    *) echo "Use application or monitoring" >&2; exit 1 ;;
  esac
}
db_state() {
  aws rds describe-db-instances --db-instance-identifier "$1" --query 'DBInstances[0].DBInstanceStatus' --output text --region "$REGION"
}
confirm_exact() {
  local expected="$1" typed
  [[ -t 0 ]] || { echo "Interactive confirmation required: $expected" >&2; exit 1; }
  printf 'Type exactly [%s] to continue: ' "$expected"
  read -r typed
  [[ "$typed" == "$expected" ]] || { echo 'Confirmation mismatch; no change requested.' >&2; exit 1; }
}
scale_service() {
  local component="$1" count="$2" service max minimum suspended
  [[ "$count" =~ ^[0-9]+$ ]] || { echo 'Count must be an integer.' >&2; exit 1; }
  count=$((10#$count))
  service="$(service_id "$component")"
  case "$component" in
    frontend) max="$(read_value "$TFVARS" frontend_max_task_count 6)" ;;
    backend) max="$(read_value "$TFVARS" backend_max_task_count 6)" ;;
    monitoring)
      [[ "$count" -le 1 ]] || { echo 'Monitoring is a single stateful task: accepted values are 0 or 1.' >&2; exit 1; }
      if [[ "$count" -eq 1 ]]; then
        [[ "$(db_state "$(db_identifier monitoring)")" == available ]] || { echo 'Monitoring RDS must be available first.' >&2; exit 1; }
      fi
      aws ecs update-service --cluster "$CLUSTER" --service "$service" --desired-count "$count" --region "$REGION" >/dev/null
      printf '%s desiredCount=%s\n' "$service" "$count"
      return
      ;;
  esac
  [[ "$count" -le "$max" ]] || { echo "$component limit from config/dev.tfvars is $max." >&2; exit 1; }
  if [[ "$component" == backend && "$count" -gt 0 ]]; then
    [[ "$(db_state "$(db_identifier application)")" == available ]] || { echo 'Application RDS must be available before starting backend.' >&2; exit 1; }
  fi
  minimum="$count"
  suspended=true
  [[ "$count" -gt 0 ]] && suspended=false
  aws application-autoscaling register-scalable-target --service-namespace ecs --resource-id "service/$CLUSTER/$service" --scalable-dimension ecs:service:DesiredCount --min-capacity "$minimum" --max-capacity "$max" --suspended-state "{\"DynamicScalingInSuspended\":$suspended,\"DynamicScalingOutSuspended\":$suspended,\"ScheduledScalingSuspended\":$suspended}" --region "$REGION" >/dev/null
  aws ecs update-service --cluster "$CLUSTER" --service "$service" --desired-count "$count" --region "$REGION" >/dev/null
  printf '%s desiredCount=%s autoscalingMin=%s\n' "$service" "$count" "$minimum"
}
stop_start() {
  local action="$1" target="$2"
  case "$target" in
    application)
      if [[ "$action" == stop ]]; then scale_service frontend 0; scale_service backend 0
      else scale_service backend "$(read_value "$TFVARS" backend_desired_task_count 2)"; scale_service frontend "$(read_value "$TFVARS" frontend_desired_task_count 2)"; fi
      ;;
    frontend|backend|monitoring)
      if [[ "$action" == stop ]]; then scale_service "$target" 0
      elif [[ "$target" == monitoring ]]; then scale_service monitoring 1
      elif [[ "$target" == backend ]]; then scale_service backend "$(read_value "$TFVARS" backend_desired_task_count 2)"
      else scale_service frontend "$(read_value "$TFVARS" frontend_desired_task_count 2)"; fi
      ;;
    *) echo 'Use application, frontend, backend or monitoring.' >&2; exit 1 ;;
  esac
}
db_command() {
  local action="$1" kind="$2" identifier state frontend backend monitoring
  identifier="$(db_identifier "$kind")"
  state="$(db_state "$identifier")"
  if [[ "$action" == status ]]; then echo "$identifier: $state"; return; fi
  if [[ "$action" == stop ]]; then
    if [[ "$kind" == application ]]; then
      frontend="$(desired_count "$(service_id frontend)")"
      backend="$(desired_count "$(service_id backend)")"
      [[ "$frontend" == 0 && "$backend" == 0 ]] || { echo 'Stop frontend and backend ECS tasks before stopping application RDS.' >&2; exit 1; }
    else
      monitoring="$(desired_count "$(service_id monitoring)")"
      [[ "$monitoring" == 0 ]] || { echo 'Stop monitoring ECS before stopping monitoring RDS.' >&2; exit 1; }
    fi
    [[ "$state" == available ]] || { echo "$identifier is $state; stop requires available." >&2; exit 1; }
    confirm_exact "STOP $identifier"
    aws rds stop-db-instance --db-instance-identifier "$identifier" --region "$REGION" >/dev/null
  elif [[ "$action" == start ]]; then
    [[ "$state" == stopped ]] || { echo "$identifier is $state; start requires stopped." >&2; exit 1; }
    confirm_exact "START $identifier"
    aws rds start-db-instance --db-instance-identifier "$identifier" --region "$REGION" >/dev/null
    echo 'Wait until RDS reports available before starting its ECS service.'
  else
    echo 'Use db status|stop|start application|monitoring.' >&2; exit 1
  fi
}

main() {
  local action="${1:-menu}"
  shift || true
  case "$action" in
    help|-h|--help) help ;;
    menu)
      require aws
      while true; do
        printf '\nNOVA Ops %s/%s (%s)\n1 Overview\n2 ECS services\n3 Current-month costs\n4 Resource inventory\n0 Exit\nChoice: ' "$PROJECT" "$ENVIRONMENT" "$REGION"
        read -r choice || break
        case "$choice" in
          1) preflight; overview ;;
          2) preflight; services ;;
          3) preflight; costs ;;
          4) preflight; inventory ;;
          0) break ;;
          *) echo 'Invalid option.' ;;
        esac
      done
      ;;
    *) preflight
      case "$action" in
        overview|status) overview ;;
        services) services ;;
        inventory) inventory ;;
        costs) costs "$@" ;;
        logs) logs "$@" ;;
        scale) [[ $# -eq 2 ]] || { echo 'Usage: scale frontend|backend|monitoring N' >&2; exit 1; }; scale_service "$1" "$2" ;;
        stop|start) [[ $# -eq 1 ]] || { echo "Usage: $action application|frontend|backend|monitoring" >&2; exit 1; }; stop_start "$action" "$1" ;;
        db) [[ $# -eq 2 ]] || { echo 'Usage: db status|stop|start application|monitoring' >&2; exit 1; }; db_command "$1" "$2" ;;
        restart)
          [[ $# -eq 1 ]] || { echo 'Usage: restart frontend|backend|monitoring' >&2; exit 1; }
          service="$(service_id "$1")"
          [[ "$(desired_count "$service")" -gt 0 ]] || { echo 'Service is stopped; start it before restart.' >&2; exit 1; }
          aws ecs update-service --cluster "$CLUSTER" --service "$service" --force-new-deployment --region "$REGION" >/dev/null
          ;;
        *) help; echo "Unknown action: $action" >&2; exit 1 ;;
      esac
      ;;
  esac
}
main "$@"
