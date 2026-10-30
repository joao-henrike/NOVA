#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG_ENV="$ROOT_DIR/config/dev.env"
TFVARS_FILE="$ROOT_DIR/config/dev.tfvars"
SECRET_DIR="$ROOT_DIR/.deploy"
SECRET_FILE="$SECRET_DIR/grafana-admin-password"
TOOLS_BIN="$ROOT_DIR/.tools/bin"
TF_DATA_DIR="/tmp/nova-terraform-data"
TF_PLUGIN_CACHE_DIR="/tmp/nova-terraform-provider-cache"
TF_CLI_CONFIG_FILE="/tmp/nova-terraformrc"

[ -f "$CONFIG_ENV" ] || { echo "Missing $CONFIG_ENV" >&2; exit 1; }
[ -f "$TFVARS_FILE" ] || { echo "Missing $TFVARS_FILE" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$CONFIG_ENV"
set +a

export PATH="$TOOLS_BIN:$PATH"
export TF_DATA_DIR
export TF_PLUGIN_CACHE_DIR
export TF_CLI_CONFIG_FILE

rm -rf "$TF_DATA_DIR" "$TF_PLUGIN_CACHE_DIR"
mkdir -p "$TF_DATA_DIR" "$TF_PLUGIN_CACHE_DIR"
printf 'plugin_cache_dir = "%s"\n' "$TF_PLUGIN_CACHE_DIR" > "$TF_CLI_CONFIG_FILE"

log() { printf '\n==> %s\n' "$*"; }
fatal() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

command -v terraform >/dev/null 2>&1 || fatal "Terraform is unavailable. Run make deploy from the repository root."
command -v aws >/dev/null 2>&1 || fatal "AWS CLI is unavailable. Run make deploy from the repository root."
command -v docker >/dev/null 2>&1 || fatal "Docker is unavailable."
command -v jq >/dev/null 2>&1 || fatal "jq is required by the deployment automation."
command -v curl >/dev/null 2>&1 || fatal "curl is required by the deployment automation."

git_branch="$(git branch --show-current)"
[ "$git_branch" = "Joao" ] || fatal "Deployment is restricted to branch Joao; current branch: ${git_branch:-detached HEAD}."

test -z "$(git status --porcelain)" || fatal "Working tree contains uncommitted or untracked changes. Commit or stash them before deployment."

log "Checking AWS identity"
actual_account="$(aws sts get-caller-identity --query Account --output text)"
[ "$actual_account" = "$EXPECTED_AWS_ACCOUNT_ID" ] || fatal "AWS account mismatch. Expected $EXPECTED_AWS_ACCOUNT_ID, got $actual_account."
log "AWS account: $actual_account"
log "AWS region : $AWS_REGION"

mkdir -p "$SECRET_DIR"
chmod 700 "$SECRET_DIR"

if [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
  printf '%s' "$GRAFANA_ADMIN_PASSWORD" > "$SECRET_FILE"
elif [ -s "$SECRET_FILE" ]; then
  GRAFANA_ADMIN_PASSWORD="$(cat "$SECRET_FILE")"
else
  log "Generating local Grafana administrator password"
  GRAFANA_ADMIN_PASSWORD="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"
  printf '%s' "$GRAFANA_ADMIN_PASSWORD" > "$SECRET_FILE"
fi

chmod 600 "$SECRET_FILE"
password_length="$(wc -c < "$SECRET_FILE")"
[ "$password_length" -ge 12 ] || fatal "Grafana password must contain at least 12 characters."
export TF_VAR_grafana_admin_password="$GRAFANA_ADMIN_PASSWORD"
unset GRAFANA_ADMIN_PASSWORD

log "Provisioning separate PostgreSQL runtime and migrator credentials"
"$ROOT_DIR/scripts/provision-db-credentials.sh"
[ -s "$SECRET_DIR/db-secret-arns.env" ] || fatal "Database credential ARNs were not written."
# shellcheck disable=SC1090
source "$SECRET_DIR/db-secret-arns.env"
[ -n "${DB_RUNTIME_SECRET_ARN:-}" ] || fatal "Runtime database secret ARN is missing."
[ -n "${DB_MIGRATOR_SECRET_ARN:-}" ] || fatal "Migration database secret ARN is missing."
export TF_VAR_db_runtime_secret_arn="$DB_RUNTIME_SECRET_ARN"
export TF_VAR_db_migrator_secret_arn="$DB_MIGRATOR_SECRET_ARN"

log "Provisioning backend JWT and optional OAuth configuration"
"$ROOT_DIR/scripts/provision-backend-auth-secret.sh"
[ -s "$SECRET_DIR/backend-auth-secret-arn.env" ] || fatal "Backend authentication secret ARN was not written."
# shellcheck disable=SC1090
source "$SECRET_DIR/backend-auth-secret-arn.env"
[ -n "${BACKEND_AUTH_SECRET_ARN:-}" ] || fatal "Backend authentication secret ARN is missing."
export TF_VAR_backend_auth_secret_arn="$BACKEND_AUTH_SECRET_ARN"

IMAGE_TAG="${DEPLOY_TAG:-$(git rev-parse --short=12 HEAD)}"
[[ "$IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || fatal "Invalid deployment image tag: $IMAGE_TAG."

export TF_VAR_frontend_image_tag="$IMAGE_TAG"
export TF_VAR_backend_image_tag="$IMAGE_TAG"

log "Ensuring the protected Terraform state bucket exists"
"$ROOT_DIR/scripts/ensure-terraform-state.sh"

log "Initializing Terraform remote state"
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="key=$TF_STATE_KEY" \
  -reconfigure \
  -input=false \
  -no-color

APPLICATION_PLAN="/tmp/nova-application-$IMAGE_TAG.tfplan"
APPLICATION_JSON="/tmp/nova-application-$IMAGE_TAG.json"
state_file=""
state_error=""
frontend_repo=""
backend_repo=""
cleanup() {
  local files=("$APPLICATION_PLAN" "$APPLICATION_JSON" "/tmp/nova-baseline-$IMAGE_TAG.tfplan" "/tmp/nova-baseline-$IMAGE_TAG.json")
  [ -z "${state_file:-}" ] || files+=("$state_file")
  [ -z "${state_error:-}" ] || files+=("$state_error")
  rm -f -- "${files[@]}"
  if [ "${KEEP_LOCAL_IMAGES:-0}" != "1" ]; then
    [ -n "${frontend_repo:-}" ] && docker image rm "$frontend_repo:$IMAGE_TAG" >/dev/null 2>&1 || true
    [ -n "${backend_repo:-}" ] && docker image rm "$backend_repo:$IMAGE_TAG" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

state_file="/tmp/nova-state-$IMAGE_TAG.txt"
state_error="/tmp/nova-state-$IMAGE_TAG.err"
rm -f "$state_file" "$state_error"

if terraform state list >"$state_file" 2>"$state_error"; then
  if [ -s "$state_file" ]; then
    log "Existing Terraform state detected; skipping fresh infrastructure baseline"
  else
    fatal "Terraform state command succeeded but returned no resources."
  fi
else
  if grep -q "No state file was found" "$state_error"; then
    log "No Terraform resources found; creating a fresh infrastructure baseline"

    BASELINE_PLAN="/tmp/nova-baseline-$IMAGE_TAG.tfplan"
    BASELINE_JSON="/tmp/nova-baseline-$IMAGE_TAG.json"

    terraform plan \
      -refresh=false \
      -lock=true \
      -input=false \
      -no-color \
      -var-file="$TFVARS_FILE" \
      -var='deploy_application=false' \
      -var="frontend_image_tag=$IMAGE_TAG" \
      -var="backend_image_tag=$IMAGE_TAG" \
      -out="$BASELINE_PLAN"

    terraform show -json "$BASELINE_PLAN" > "$BASELINE_JSON"

    BASELINE_DELETES="$(jq '[.resource_changes[]? | select(.mode == "managed") | select(any(.change.actions[]?; . == "delete"))] | length' "$BASELINE_JSON")"
    [ "$BASELINE_DELETES" -eq 0 ] || fatal "Fresh baseline plan contains deletions."

    log "Applying infrastructure baseline"
    terraform apply -input=false -auto-approve "$BASELINE_PLAN"
  else
    cat "$state_error" >&2
    fatal "Terraform state inspection failed."
  fi
fi

frontend_repo="$(terraform output -raw frontend_ecr_repository_url)"
backend_repo="$(terraform output -raw backend_ecr_repository_url)"

log "Authenticating Docker to ECR"
registry="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$AWS_REGION.amazonaws.com"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$registry" >/dev/null

log "Building frontend image: $IMAGE_TAG"
docker build --pull -t "$frontend_repo:$IMAGE_TAG" apps/frontend

log "Building backend image: $IMAGE_TAG"
docker build --pull -t "$backend_repo:$IMAGE_TAG" apps/backend

log "Pushing immutable application images"
docker push "$frontend_repo:$IMAGE_TAG"
docker push "$backend_repo:$IMAGE_TAG"

log "Planning application activation"
terraform plan \
  -refresh=true \
  -lock=true \
  -input=false \
  -no-color \
  -var-file="$TFVARS_FILE" \
  -var='deploy_application=true' \
  -var="frontend_image_tag=$IMAGE_TAG" \
  -var="backend_image_tag=$IMAGE_TAG" \
  -out="$APPLICATION_PLAN"

terraform show -json "$APPLICATION_PLAN" > "$APPLICATION_JSON"

APP_DELETES="$(jq '[.resource_changes[]? | select(.mode == "managed") | select(any(.change.actions[]?; . == "delete"))] | length' "$APPLICATION_JSON")"
APP_UNEXPECTED="$(jq '[.resource_changes[]? | select(.change.actions != ["no-op"]) | select(.address | test("^(aws_ecs_task_definition\\.frontend|aws_ecs_task_definition\\.backend|aws_ecs_task_definition\\.db_bootstrap|aws_ecs_task_definition\\.db_migration|aws_ecs_task_definition\\.monitoring|aws_ecs_service\\.frontend|aws_ecs_service\\.backend|aws_ecs_service\\.monitoring|aws_appautoscaling_target\\.frontend|aws_appautoscaling_target\\.backend|aws_iam_role\\.ecs_backend_execution|aws_iam_role\\.ecs_migration_execution|aws_iam_role\\.ecs_db_bootstrap_execution|aws_iam_role_policy\\.ecs_execution|aws_iam_role_policy\\.ecs_backend_execution|aws_iam_role_policy\\.ecs_migration_execution|aws_iam_role_policy\\.ecs_db_bootstrap_execution|aws_iam_role_policy\\.ecs_monitoring_execution|aws_security_group\\.database_tasks|aws_vpc_security_group_egress_rule\\.database_tasks_https|aws_vpc_security_group_egress_rule\\.database_tasks_to_rds|aws_vpc_security_group_ingress_rule\\.rds_from_database_tasks|aws_cloudwatch_log_group\\.frontend|aws_cloudwatch_log_group\\.backend|aws_cloudwatch_log_group\\.db_bootstrap|aws_cloudwatch_log_group\\.db_migration|aws_cloudwatch_log_group\\.monitoring)$") | not) | .address] | length' "$APPLICATION_JSON")"

[ "$APP_DELETES" -eq 0 ] || fatal "Application activation plan contains deletions."
[ "$APP_UNEXPECTED" -eq 0 ] || fatal "Application activation plan modifies resources outside the application ECS scope."

log "Activating frontend/backend ECS services"
terraform apply -input=false -auto-approve "$APPLICATION_PLAN"

cluster="$(terraform output -raw ecs_cluster_name)"
frontend_service="$(terraform output -raw frontend_ecs_service_name)"
backend_service="$(terraform output -raw backend_ecs_service_name)"
monitoring_service="$(terraform output -raw monitoring_ecs_service_name)"

log "Waiting for ECS services to stabilize"
aws ecs wait services-stable \
  --cluster "$cluster" \
  --services "$frontend_service" "$backend_service" "$monitoring_service" \
  --region "$AWS_REGION"

run_one_off_database_task() {
  local task_definition="$1"
  local container_name="$2"
  local label="$3"
  local task_arn
  local exit_code

  log "Starting $label as a private Fargate task"
  task_arn="$(aws ecs run-task \
    --cluster "$cluster" \
    --task-definition "$task_definition" \
    --launch-type FARGATE \
    --network-configuration "$network_config" \
    --region "$AWS_REGION" \
    --query "tasks[0].taskArn" \
    --output text)"

  [ -n "$task_arn" ] && [ "$task_arn" != "None" ] || fatal "Failed to start $label task."

  aws ecs wait tasks-stopped \
    --cluster "$cluster" \
    --tasks "$task_arn" \
    --region "$AWS_REGION"

  exit_code="$(aws ecs describe-tasks \
    --cluster "$cluster" \
    --tasks "$task_arn" \
    --region "$AWS_REGION" \
    --query "tasks[0].containers[?name=='$container_name'].exitCode | [0]" \
    --output text)"

  if [ "$exit_code" != "0" ]; then
    aws ecs describe-tasks \
      --cluster "$cluster" \
      --tasks "$task_arn" \
      --region "$AWS_REGION" \
      --query "tasks[0].{stoppedReason:stoppedReason,containers:containers[*].{name:name,exitCode:exitCode,reason:reason}}" \
      --output json >&2
    fatal "$label task failed with exit code $exit_code."
  fi
}

database_sg="$(terraform output -raw database_tasks_security_group_id)"
subnets="$(terraform output -json private_app_subnet_ids | jq -c '[.[]]')"
network_config="$(jq -nc --argjson subnets "$subnets" --arg sg "$database_sg" '{awsvpcConfiguration:{subnets:$subnets,securityGroups:[$sg],assignPublicIp:"DISABLED"}}')"

run_one_off_database_task \
  "$(terraform output -raw db_bootstrap_task_definition_arn)" \
  "db-bootstrap" \
  "database role bootstrap"

run_one_off_database_task \
  "$(terraform output -raw db_migration_task_definition_arn)" \
  "db-migration" \
  "Alembic migrations"

# The bootstrap runs again after Alembic so the DML-only runtime role receives
# grants on any tables/sequences introduced by the just-applied migrations.
run_one_off_database_task \
  "$(terraform output -raw db_bootstrap_task_definition_arn)" \
  "db-bootstrap" \
  "post-migration runtime grants"

log "Running ALB smoke tests"
base_url="$(terraform output -raw alb_application_url)"
base_url="${base_url%/}"

curl --fail --silent --show-error --retry 20 --retry-delay 5 "$base_url/" >/dev/null
curl --fail --silent --show-error --retry 20 --retry-delay 5 "$base_url/api/health" >/dev/null
curl --fail --silent --show-error --retry 20 --retry-delay 5 "$base_url/api/info" >/dev/null
curl --fail --silent --show-error --retry 20 --retry-delay 5 "$base_url/api/health/db" >/dev/null

status="$(curl --silent --output /tmp/nova-items.json --write-out '%{http_code}' "$base_url/api/items")"
[ "$status" = "401" ] || fatal "Expected /api/items to return 401, got $status."

curl --fail --silent --show-error --retry 20 --retry-delay 5 "$base_url/grafana/api/health" >/dev/null

log "Deployment completed successfully"
printf '\nEnvironment : %s/%s\n' "cloudstart" "dev"
printf 'Image tag  : %s\n' "$IMAGE_TAG"
printf 'ALB        : %s\n' "$base_url"
printf 'Grafana    : %s\n' "$(terraform output -raw grafana_url)"
printf 'State key  : %s\n' "$TF_STATE_KEY"
printf '\nGrafana password is stored only at: %s\n' "$SECRET_FILE"
