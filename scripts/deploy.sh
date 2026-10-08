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
[ "$git_branch" = "Joao" ] || fatal "Deployment is restricted to branch Joao; current branch: \${git_branch:-detached HEAD}."

git diff --quiet && git diff --cached --quiet || fatal "Working tree contains uncommitted changes. Commit or stash them before deployment."

log "Checking AWS identity"
actual_account="$(aws sts get-caller-identity --query Account --output text)"
[ "$actual_account" = "$EXPECTED_AWS_ACCOUNT_ID" ] || fatal "AWS account mismatch. Expected $EXPECTED_AWS_ACCOUNT_ID, got $actual_account."
log "AWS account: $actual_account"
log "AWS region : $AWS_REGION"

mkdir -p "$SECRET_DIR"
chmod 700 "$SECRET_DIR"

if [ -n "\${GRAFANA_ADMIN_PASSWORD:-}" ]; then
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

IMAGE_TAG="\${DEPLOY_TAG:-$(git rev-parse --short=12 HEAD)}"
[ -n "$IMAGE_TAG" ] || fatal "Could not determine deployment image tag."

export TF_VAR_frontend_image_tag="$IMAGE_TAG"
export TF_VAR_backend_image_tag="$IMAGE_TAG"

log "Initializing Terraform remote state"
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="key=$TF_STATE_KEY" \
  -reconfigure \
  -input=false \
  -no-color

BASELINE_PLAN="/tmp/nova-baseline-$IMAGE_TAG.tfplan"
BASELINE_JSON="/tmp/nova-baseline-$IMAGE_TAG.json"
APPLICATION_PLAN="/tmp/nova-application-$IMAGE_TAG.tfplan"
APPLICATION_JSON="/tmp/nova-application-$IMAGE_TAG.json"

log "Planning fresh infrastructure baseline"
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

BASELINE_DELETES="$(jq '[.resource_changes[]? | select(any(.change.actions[]?; . == "delete"))] | length' "$BASELINE_JSON")"
BASELINE_NONCREATE="$(jq '[.resource_changes[]? | select(.change.actions != ["create"]) | .address] | length' "$BASELINE_JSON")"

[ "$BASELINE_DELETES" -eq 0 ] || fatal "Fresh baseline plan contains deletions."
[ "$BASELINE_NONCREATE" -eq 0 ] || fatal "Fresh baseline plan contains non-create resource actions."

log "Applying infrastructure baseline"
terraform apply -input=false -auto-approve "$BASELINE_PLAN"

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

APP_DELETES="$(jq '[.resource_changes[]? | select(any(.change.actions[]?; . == "delete"))] | length' "$APPLICATION_JSON")"
APP_UNEXPECTED="$(jq '[.resource_changes[]? | select(.change.actions != ["no-op"]) | select(.address | test("^(aws_ecs_task_definition\\.frontend|aws_ecs_task_definition\\.backend|aws_ecs_service\\.frontend|aws_ecs_service\\.backend|aws_appautoscaling_target\\.frontend|aws_appautoscaling_target\\.backend)$") | not) | .address] | length' "$APPLICATION_JSON")"

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

log "Running Alembic migrations in a private Fargate task"
backend_task_definition="$(terraform output -raw backend_task_definition_arn)"
backend_sg="$(terraform output -raw backend_security_group_id)"
subnets="$(terraform output -json private_app_subnet_ids | jq -c '[.[]]')"
network_config="$(jq -nc --argjson subnets "$subnets" --arg sg "$backend_sg" '{awsvpcConfiguration:{subnets:$subnets,securityGroups:[$sg],assignPublicIp:"DISABLED"}}')"
overrides="$(jq -nc '{containerOverrides:[{name:"backend",command:["alembic","upgrade","head"]}]}')"

task_arn="$(aws ecs run-task \
  --cluster "$cluster" \
  --task-definition "$backend_task_definition" \
  --launch-type FARGATE \
  --network-configuration "$network_config" \
  --overrides "$overrides" \
  --region "$AWS_REGION" \
  --query "tasks[0].taskArn" \
  --output text)"

[ -n "$task_arn" ] && [ "$task_arn" != "None" ] || fatal "Failed to start migration task."

aws ecs wait tasks-stopped \
  --cluster "$cluster" \
  --tasks "$task_arn" \
  --region "$AWS_REGION"

exit_code="$(aws ecs describe-tasks \
  --cluster "$cluster" \
  --tasks "$task_arn" \
  --region "$AWS_REGION" \
  --query "tasks[0].containers[?name=='backend'].exitCode | [0]" \
  --output text)"

[ "$exit_code" = "0" ] || fatal "Migration task failed with exit code $exit_code."

log "Running ALB smoke tests"
alb_dns="$(terraform output -raw alb_dns_name)"
base_url="http://$alb_dns"

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
