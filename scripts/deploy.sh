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
[[ "$git_branch" == "main" || "$git_branch" == "Joao" || "$git_branch" == "TESTE1" ]] || fatal "Deployment is restricted to main/Joao/TESTE1; current branch: ${git_branch:-detached HEAD}."

test -z "$(git status --porcelain)" || fatal "Working tree contains uncommitted or untracked changes. Commit or stash them before deployment."

log "Checking AWS identity"
actual_account="$(aws sts get-caller-identity --query Account --output text)"
[ "$actual_account" = "$EXPECTED_AWS_ACCOUNT_ID" ] || fatal "AWS account mismatch. Expected $EXPECTED_AWS_ACCOUNT_ID, got $actual_account."
log "AWS account: $actual_account"
log "AWS region : $AWS_REGION"

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

# Read-only ownership audit comes before any secret provisioning or Terraform apply.
log "Auditing live resources still owned by legacy Terraform states"
python3 "$ROOT_DIR/scripts/check-cloud-state-ownership.py"

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
bash "$ROOT_DIR/scripts/provision-db-credentials.sh"
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

# A state containing network or ECR resources is not proof that the baseline
# is complete. Reconcile a partial baseline before building/pushing images.
# Never use deploy_application=false to reconcile a state with application
# services: doing so may alter active ECS service settings.
reconcile_baseline() {
  local baseline_plan="/tmp/nova-baseline-$IMAGE_TAG.tfplan"
  local baseline_json="/tmp/nova-baseline-$IMAGE_TAG.json"

  log "Planning safe infrastructure baseline reconciliation (refresh enabled)"
  terraform plan \
    -refresh=true \
    -lock=true \
    -input=false \
    -no-color \
    -var-file="$TFVARS_FILE" \
    -var='deploy_application=false' \
    -var="frontend_image_tag=$IMAGE_TAG" \
    -var="backend_image_tag=$IMAGE_TAG" \
    -out="$baseline_plan"

  terraform show -json "$baseline_plan" > "$baseline_json"
  bash "$ROOT_DIR/scripts/check-baseline-plan.sh" "$baseline_json"

  if jq -e '[.resource_changes[]? | select(.mode == "managed")
    | select(.change.actions != ["no-op"])] | length > 0' "$baseline_json" >/dev/null; then
    log "Applying guarded infrastructure baseline reconciliation"
    terraform apply -input=false -auto-approve "$baseline_plan"
  else
    log "Infrastructure baseline has no managed-resource changes"
  fi
}

if terraform state list >"$state_file" 2>"$state_error"; then
  if grep -Eq '^aws_ecs_service\.(frontend|backend|monitoring)$' "$state_file"; then
    log "State contains application/monitoring ECS services; skipping baseline to protect active workloads"
    log "The application plan guard will reject infrastructure drift that requires separate reconciliation"
  else
    log "No ECS services recorded in state; reconciling baseline even if other infrastructure exists"
    reconcile_baseline
  fi
elif grep -q "No state file was found" "$state_error"; then
  log "No Terraform state found; creating guarded infrastructure baseline"
  reconcile_baseline
else
  cat "$state_error" >&2
  fatal "Terraform state inspection failed."
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

log "Planning application task revisions with service activation deferred until after migrations"
terraform plan \
  -refresh=true \
  -lock=true \
  -input=false \
  -no-color \
  -var-file="$TFVARS_FILE" \
  -var='deploy_application=true' \
  -var='start_application_services=false' \
  -var="frontend_image_tag=$IMAGE_TAG" \
  -var="backend_image_tag=$IMAGE_TAG" \
  -out="$APPLICATION_PLAN"

terraform show -json "$APPLICATION_PLAN" > "$APPLICATION_JSON"

# Application changes may replace ECS task definitions, but must not modify unrelated infrastructure.
bash "$ROOT_DIR/scripts/check-application-plan.sh" "$APPLICATION_JSON"

log "Registering application task revisions while keeping live service revisions unchanged"
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

log "Activating frontend/backend revisions after database migrations"
bash "$ROOT_DIR/scripts/activate-application-services.sh"

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
