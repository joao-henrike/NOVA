#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CONFIG_ENV="$ROOT_DIR/config/dev.env"
TFVARS_FILE="$ROOT_DIR/config/dev.tfvars"
SECRET_DIR="$ROOT_DIR/.deploy"
TOOLS_BIN="$ROOT_DIR/.tools/bin"
OPS_DATA_DIR="$SECRET_DIR/terraform-ops-data"
PLUGIN_CACHE_DIR="$SECRET_DIR/terraform-provider-cache"
TF_CLI_CONFIG_FILE="$SECRET_DIR/terraform-ops.tfrc"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Required command unavailable: $1"; }

read_tfvar() {
  local key="$1" fallback="$2" value=""
  value="$(awk -v k="$key" '$1 == k && $2 == "=" { $1=""; $2=""; sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+#.*/, ""); gsub(/^"|"$/, ""); print; exit }' "$TFVARS_FILE")"
  printf '%s' "${value:-$fallback}"
}

[[ -f "$CONFIG_ENV" && -f "$TFVARS_FILE" ]] || fail "Missing committed development configuration."
set -a
# shellcheck disable=SC1090
source "$CONFIG_ENV"
set +a
: "${AWS_REGION:?AWS_REGION is required}"
: "${EXPECTED_AWS_ACCOUNT_ID:?EXPECTED_AWS_ACCOUNT_ID is required}"
: "${TF_STATE_BUCKET:?TF_STATE_BUCKET is required}"
: "${TF_STATE_KEY:?TF_STATE_KEY is required}"

export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
export PATH="$TOOLS_BIN:$PATH"
export TF_DATA_DIR="$OPS_DATA_DIR" TF_PLUGIN_CACHE_DIR="$PLUGIN_CACHE_DIR" TF_CLI_CONFIG_FILE
PROJECT_NAME="$(read_tfvar project_name cloudstart)"
ENVIRONMENT="$(read_tfvar environment dev)"
CLUSTER="${PROJECT_NAME}-${ENVIRONMENT}-cluster"
APP_DB="${PROJECT_NAME}-${ENVIRONMENT}-db"
MONITORING_DB="${PROJECT_NAME}-${ENVIRONMENT}-monitoring-db"
FRONTEND_DESIRED="$(read_tfvar frontend_desired_task_count 2)"
BACKEND_DESIRED="$(read_tfvar backend_desired_task_count 2)"
FRONTEND_MIN="$(read_tfvar frontend_min_task_count 2)"
BACKEND_MIN="$(read_tfvar backend_min_task_count 2)"
FRONTEND_MAX="$(read_tfvar frontend_max_task_count 6)"
BACKEND_MAX="$(read_tfvar backend_max_task_count 6)"
MONITORING_DESIRED="$(read_tfvar monitoring_desired_count 1)"

require_command aws
require_command jq
require_command terraform
require_command git
[[ "$(git branch --show-current)" == "TESTE1" ]] || fail "Full infrastructure controls are only allowed from TESTE1."
actual_account="$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")"
[[ "$actual_account" == "$EXPECTED_AWS_ACCOUNT_ID" ]] || fail "AWS account mismatch: expected $EXPECTED_AWS_ACCOUNT_ID, got $actual_account."

mkdir -p "$SECRET_DIR" "$OPS_DATA_DIR" "$PLUGIN_CACHE_DIR"
chmod 700 "$SECRET_DIR" "$OPS_DATA_DIR" "$PLUGIN_CACHE_DIR"
printf 'plugin_cache_dir = "%s"\n' "$PLUGIN_CACHE_DIR" > "$TF_CLI_CONFIG_FILE"
chmod 600 "$TF_CLI_CONFIG_FILE"

load_runtime_variables() {
  local grafana_file="$SECRET_DIR/grafana-admin-password"
  local db_file="$SECRET_DIR/db-secret-arns.env"
  local auth_file="$SECRET_DIR/backend-auth-secret-arn.env"
  [[ -s "$grafana_file" && -s "$db_file" && -s "$auth_file" ]] || fail "Missing local .deploy secrets/ARN metadata. Reuse the deployment workspace; refusing to rotate credentials or guess ARNs."
  # shellcheck disable=SC1090
  source "$db_file"
  # shellcheck disable=SC1090
  source "$auth_file"
  [[ -n "${DB_RUNTIME_SECRET_ARN:-}" && -n "${DB_MIGRATOR_SECRET_ARN:-}" && -n "${BACKEND_AUTH_SECRET_ARN:-}" ]] || fail "Required secret ARN metadata is incomplete."
  export TF_VAR_grafana_admin_password
  TF_VAR_grafana_admin_password="$(cat "$grafana_file")"
  export TF_VAR_db_runtime_secret_arn="$DB_RUNTIME_SECRET_ARN"
  export TF_VAR_db_migrator_secret_arn="$DB_MIGRATOR_SECRET_ARN"
  export TF_VAR_backend_auth_secret_arn="$BACKEND_AUTH_SECRET_ARN"
  export TF_VAR_deploy_application=true TF_VAR_start_application_services=false

  local component service td image container tag
  for component in frontend backend; do
    service="${PROJECT_NAME}-${ENVIRONMENT}-${component}"
    td="$(aws ecs describe-services --cluster "$CLUSTER" --services "$service" --query 'services[0].taskDefinition' --output text --region "$AWS_REGION")"
    [[ -n "$td" && "$td" != "None" ]] || fail "Could not find active ECS task definition for $service."
    container="$(read_tfvar "${component}_container_name" "$component")"
    image="$(aws ecs describe-task-definition --task-definition "$td" --query "taskDefinition.containerDefinitions[?name=='$container'].image | [0]" --output text --region "$AWS_REGION")"
    [[ -n "$image" && "$image" != "None" && "$image" == *:* ]] || fail "Could not determine deployed image tag for $service."
    tag="${image##*:}"
    [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || fail "Invalid active image tag for $service: $tag"
    export "TF_VAR_${component}_image_tag=$tag"
  done
}

initialize_terraform() {
  log "Verifying protected Terraform state bucket"
  bash "$ROOT_DIR/scripts/ensure-terraform-state.sh" --verify-only
  log "Initializing remote Terraform state"
  terraform init -backend-config="bucket=$TF_STATE_BUCKET" -backend-config="region=$AWS_REGION" -backend-config="key=$TF_STATE_KEY" -reconfigure -input=false -no-color
}

plan_scope_is_safe() {
  local mode="$1" plan_json="$2" bad="$SECRET_DIR/terraform-ops-rejections.txt"
  : > "$bad"
  while IFS=$'\t' read -r address actions; do
    [[ -n "$address" ]] || continue
    if ! [[ "$address" =~ ^aws_nat_gateway\.this\[.+\]$ ||
            "$address" =~ ^aws_eip\.nat\[.+\]$ ||
            "$address" =~ ^aws_route_table\.private_app\[.+\]$ ||
            "$address" =~ ^aws_lb\.this\[0\]$ ||
            "$address" =~ ^aws_lb_target_group\.(frontend|backend|grafana)\[0\]$ ||
            "$address" =~ ^aws_lb_listener\.(http|http_redirect|https)\[0\]$ ||
            "$address" =~ ^aws_lb_listener_rule\.(backend|grafana)\[0\]$ ||
            "$address" =~ ^aws_vpc_security_group_(ingress|egress)_rule\.(alb_http|alb_https|alb_to_frontend|alb_to_backend|alb_to_grafana|frontend_from_alb|backend_from_alb|monitoring_from_alb)(\[0\])?$ ||
            "$address" =~ ^aws_ecs_service\.(frontend|backend|monitoring)$ ]]; then
      printf 'Out-of-scope: %s (%s)\n' "$address" "$actions" >> "$bad"
      continue
    fi
    if [[ "$mode" == shutdown && ",$actions," == *,create,* ]]; then printf 'Create during shutdown: %s (%s)\n' "$address" "$actions" >> "$bad"; fi
    if [[ "$mode" == resume && ",$actions," == *,delete,* ]]; then printf 'Delete during resume: %s (%s)\n' "$address" "$actions" >> "$bad"; fi
    if [[ ",$actions," == *,delete,* && "$address" =~ ^aws_ecs_service\. ]]; then printf 'ECS service deletion is forbidden: %s\n' "$address" >> "$bad"; fi
  done < <(jq -r '.resource_changes[]? | select(.change.actions != ["no-op"]) | [.address, (.change.actions | join(","))] | @tsv' "$plan_json")
  [[ ! -s "$bad" ]] || { cat "$bad" >&2; fail "Terraform plan exceeded the NOVA Ops allowlist. No apply performed."; }
}

create_and_review_plan() {
  local mode="$1" nat alb plan_file plan_json
  case "$mode" in
    shutdown) nat=false; alb=false ;;
    resume) nat=true; alb=true ;;
    *) fail "Unknown infrastructure mode: $mode" ;;
  esac
  plan_file="$SECRET_DIR/terraform-ops-$mode.tfplan"
  plan_json="$SECRET_DIR/terraform-ops-$mode.json"
  rm -f "$plan_file" "$plan_json"
  log "Creating $mode plan (NAT=$nat, ALB=$alb)"
  terraform plan -refresh=true -lock=true -input=false -no-color \
    -var-file="$TFVARS_FILE" \
    -var='deploy_application=true' \
    -var='start_application_services=false' \
    -var="enable_nat_gateways=$nat" \
    -var="enable_public_alb=$alb" \
    -out="$plan_file"
  chmod 600 "$plan_file"
  terraform show -json "$plan_file" > "$plan_json"
  chmod 600 "$plan_json"
  plan_scope_is_safe "$mode" "$plan_json"
  printf '\nChanges in the guarded Terraform plan:\n'
  jq -r '.resource_changes[]? | select(.change.actions != ["no-op"]) | "  \(.address) => \(.change.actions | join(","))"' "$plan_json"
  terraform show -no-color "$plan_file"
}

confirm_exact() {
  local expected="$1" typed
  [[ -t 0 ]] || fail "Interactive confirmation required; type: $expected"
  printf '\nType exactly [%s]: ' "$expected"
  read -r typed
  [[ "$typed" == "$expected" ]] || fail "Confirmation mismatch. No infrastructure apply performed."
}


service_desired_count() {
  aws ecs describe-services --cluster "$CLUSTER" --services "$1" --query 'services[0].desiredCount' --output text --region "$AWS_REGION"
}
service_running_count() {
  aws ecs describe-services --cluster "$CLUSTER" --services "$1" --query 'services[0].runningCount' --output text --region "$AWS_REGION"
}
stop_application_service() {
  local component="$1" service maximum resource_id suspended
  service="${PROJECT_NAME}-${ENVIRONMENT}-${component}"
  resource_id="service/$CLUSTER/$service"
  case "$component" in
    frontend) maximum="$FRONTEND_MAX" ;;
    backend) maximum="$BACKEND_MAX" ;;
    *) fail "Unsupported application ECS service: $component" ;;
  esac
  suspended='{"DynamicScalingInSuspended":true,"DynamicScalingOutSuspended":true,"ScheduledScalingSuspended":true}'
  aws application-autoscaling register-scalable-target --service-namespace ecs --resource-id "$resource_id" --scalable-dimension ecs:service:DesiredCount --min-capacity 0 --max-capacity "$maximum" --suspended-state "$suspended" --region "$AWS_REGION" >/dev/null
  aws ecs update-service --cluster "$CLUSTER" --service "$service" --desired-count 0 --region "$AWS_REGION" >/dev/null
  log "Requested $service desiredCount=0; scaling is suspended."
}
stop_all_workloads() {
  local frontend="${PROJECT_NAME}-${ENVIRONMENT}-frontend"
  local backend="${PROJECT_NAME}-${ENVIRONMENT}-backend"
  local monitoring="${PROJECT_NAME}-${ENVIRONMENT}-monitoring"
  stop_application_service backend
  stop_application_service frontend
  aws ecs update-service --cluster "$CLUSTER" --service "$monitoring" --desired-count 0 --region "$AWS_REGION" >/dev/null
  log "Waiting for all ECS services to become stable at zero tasks"
  aws ecs wait services-stable --cluster "$CLUSTER" --services "$frontend" "$backend" "$monitoring" --region "$AWS_REGION"
  local service desired running
  for service in "$frontend" "$backend" "$monitoring"; do
    desired="$(service_desired_count "$service")"
    running="$(service_running_count "$service")"
    [[ "$desired" == 0 && "$running" == 0 ]] || fail "$service has desired=$desired and running=$running. Refusing RDS/network shutdown."
  done
}
database_state() {
  aws rds describe-db-instances --db-instance-identifier "$1" --query 'DBInstances[0].DBInstanceStatus' --output text --region "$AWS_REGION"
}
stop_database_for_shutdown() {
  local identifier="$1" state
  state="$(database_state "$identifier")"
  case "$state" in
    available) log "Stopping RDS instance $identifier"; aws rds stop-db-instance --db-instance-identifier "$identifier" --region "$AWS_REGION" >/dev/null ;;
    stopped) log "RDS instance $identifier is already stopped." ;;
    *) fail "RDS instance $identifier is in state '$state'. Expected available or stopped." ;;
  esac
}
wait_for_database_stopped() {
  local identifier="$1" state
  state="$(database_state "$identifier")"
  [[ "$state" == stopped ]] && return
  log "Waiting for RDS instance $identifier to stop"
  aws rds wait db-instance-stopped --db-instance-identifier "$identifier" --region "$AWS_REGION"
}
start_database_for_resume() {
  local identifier="$1" state
  state="$(database_state "$identifier")"
  case "$state" in
    available) log "RDS instance $identifier is already available." ;;
    stopped) log "Starting RDS instance $identifier"; aws rds start-db-instance --db-instance-identifier "$identifier" --region "$AWS_REGION" >/dev/null ;;
    starting) log "RDS instance $identifier is already starting." ;;
    *) fail "RDS instance $identifier is in state '$state'. Resolve transition before starting workloads." ;;
  esac
}
wait_for_database_available() {
  log "Waiting for RDS instance $1 to become available"
  aws rds wait db-instance-available --db-instance-identifier "$1" --region "$AWS_REGION"
}
start_application_service() {
  local component="$1" service desired minimum maximum resource_id active_state
  service="${PROJECT_NAME}-${ENVIRONMENT}-${component}"
  case "$component" in
    frontend) desired="$FRONTEND_DESIRED"; minimum="$FRONTEND_MIN"; maximum="$FRONTEND_MAX" ;;
    backend) desired="$BACKEND_DESIRED"; minimum="$BACKEND_MIN"; maximum="$BACKEND_MAX" ;;
    *) fail "Unsupported application ECS service: $component" ;;
  esac
  resource_id="service/$CLUSTER/$service"
  active_state='{"DynamicScalingInSuspended":false,"DynamicScalingOutSuspended":false,"ScheduledScalingSuspended":false}'
  aws application-autoscaling register-scalable-target --service-namespace ecs --resource-id "$resource_id" --scalable-dimension ecs:service:DesiredCount --min-capacity "$minimum" --max-capacity "$maximum" --suspended-state "$active_state" --region "$AWS_REGION" >/dev/null
  aws ecs update-service --cluster "$CLUSTER" --service "$service" --desired-count "$desired" --region "$AWS_REGION" >/dev/null
  log "Started $service with desired=$desired, min=$minimum, max=$maximum."
}
start_all_workloads() {
  local monitoring="${PROJECT_NAME}-${ENVIRONMENT}-monitoring"
  start_application_service backend
  start_application_service frontend
  aws ecs update-service --cluster "$CLUSTER" --service "$monitoring" --desired-count "$MONITORING_DESIRED" --region "$AWS_REGION" >/dev/null
  log "Waiting for ECS services to stabilize"
  aws ecs wait services-stable --cluster "$CLUSTER" --services "${PROJECT_NAME}-${ENVIRONMENT}-frontend" "${PROJECT_NAME}-${ENVIRONMENT}-backend" "$monitoring" --region "$AWS_REGION"
}
shutdown() {
  load_runtime_variables
  initialize_terraform
  create_and_review_plan shutdown
  confirm_exact "SHUTDOWN ${PROJECT_NAME}-${ENVIRONMENT}"
  stop_all_workloads
  stop_database_for_shutdown "$APP_DB"
  stop_database_for_shutdown "$MONITORING_DB"
  wait_for_database_stopped "$APP_DB"
  wait_for_database_stopped "$MONITORING_DB"
  create_and_review_plan shutdown
  log "Applying the reviewed infrastructure shutdown plan"
  terraform apply -input=false -auto-approve "$SECRET_DIR/terraform-ops-shutdown.tfplan"
  log "NOVA infrastructure shutdown completed"
  printf '\nRemoved: ECS running tasks, public ALB/listeners/target groups, per-AZ NAT Gateways and their public IPv4 allocations.\n'
  printf 'Preserved: VPC/subnets/route tables, RDS data (instances stopped), ECR/images, secrets, logs, snapshots, and remote S3 state.\n'
  printf 'Warning: stopped RDS instances restart automatically after seven consecutive days. Storage, backups, logs, ECR, and secrets may still cost money.\n'
}
resume() {
  load_runtime_variables
  initialize_terraform
  create_and_review_plan resume
  confirm_exact "RESUME ${PROJECT_NAME}-${ENVIRONMENT}"
  log "Recreating NAT Gateways, public IPv4 addresses, ALB, listeners, and target groups"
  terraform apply -input=false -auto-approve "$SECRET_DIR/terraform-ops-resume.tfplan"
  start_database_for_resume "$APP_DB"
  start_database_for_resume "$MONITORING_DB"
  wait_for_database_available "$APP_DB"
  wait_for_database_available "$MONITORING_DB"
  start_all_workloads
  local alb_dns
  alb_dns="$(terraform output -raw alb_dns_name)"
  log "NOVA environment restored"
  printf '\nApplication ALB: http://%s/\n' "$alb_dns"
  printf 'Grafana:         http://%s/grafana/\n' "$alb_dns"
  printf '\nVerify current state with: make ops ACTION=overview\n'
}
main() {
  case "${1:-}" in
    shutdown) shutdown ;;
    resume) resume ;;
    *) printf 'Usage: %s shutdown|resume\n' "$0" >&2; exit 2 ;;
  esac
}
main "$@"
