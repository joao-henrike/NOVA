#!/usr/bin/env bash
# Publish ONLY the current apps/frontend image and roll ONLY the ECS frontend service.
# This does not modify backend, monitoring, network or database resources.
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
[[ -f config/dev.env ]] || { echo "Missing config/dev.env" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source config/dev.env
set +a

export PATH="$ROOT/.tools/bin:$PATH"
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""
export TF_DATA_DIR="${TF_DATA_DIR:-/tmp/nova-terraform-data}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for cmd in git aws terraform jq curl docker; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing $cmd"
done
docker info >/dev/null 2>&1 || die "Docker daemon unavailable"
[[ "$(git branch --show-current)" == main ]] || die "Use the main branch"
[[ -z "$(git status --porcelain)" ]] || die "Working tree is not clean"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
[[ "$ACCOUNT" == "$EXPECTED_AWS_ACCOUNT_ID" ]] || die "AWS account mismatch"
[[ "$TF_STATE_BUCKET" == "cloudstart-nova-terraform-state-$ACCOUNT" ]] || die "State bucket does not match AWS account"

WORK="$(mktemp -d /tmp/nova-frontend-only.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "Frontend-only deploy: account=$ACCOUNT region=$AWS_REGION"
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="key=$TF_STATE_KEY" \
  -reconfigure -input=false -no-color

[[ "$(terraform output -raw aws_account_id)" == "$ACCOUNT" ]] || die "Terraform state belongs to another account"

REPO="$(terraform output -raw frontend_ecr_repository_url)"
CLUSTER="$(terraform output -raw ecs_cluster_name)"
SERVICE="$(terraform output -raw frontend_ecs_service_name)"
BASE="$(terraform output -raw alb_application_url)"
[[ "$REPO" == "$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/"* ]] || die "ECR repository mismatch"

OLD_TASK="$(aws ecs describe-services --region "$AWS_REGION" --cluster "$CLUSTER" \
  --services "$SERVICE" --query 'services[0].taskDefinition' --output text)"
[[ "$OLD_TASK" == arn:aws:ecs:"$AWS_REGION":"$ACCOUNT":task-definition/* ]] || die "Frontend service missing or task definition mismatch"

TAG="ui-$(git rev-parse --short=12 HEAD)-$(date -u +%Y%m%d%H%M%S)"
echo "Building and pushing frontend image $REPO:$TAG"
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com" >/dev/null
docker build --pull -t "$REPO:$TAG" apps/frontend

# Test the exact image before publishing: a 403 from Nginx must block rollout.
echo "Checking Nginx static HTML inside the new frontend image"
TEST_CONTAINER="$(docker run --detach --rm "$REPO:$TAG")"
[[ -n "$TEST_CONTAINER" ]] || die "Failed to start the frontend smoke-test container"
smoke_cleanup() {
  docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1 || true
}
trap 'smoke_cleanup; rm -rf "$WORK"' EXIT

SMOKE_HTML=""
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if SMOKE_HTML="$(docker exec "$TEST_CONTAINER" wget -q -O - http://127.0.0.1/ 2>/dev/null)" \
    && grep -Fq 'id="apiStatus"' <<< "$SMOKE_HTML"; then
    break
  fi
  sleep 1
done

grep -Fq 'id="apiStatus"' <<< "$SMOKE_HTML" || {
  docker logs "$TEST_CONTAINER" >&2 || true
  die "Frontend Nginx did not serve the new HTML at /"
}

docker exec "$TEST_CONTAINER" wget -q -O /dev/null http://127.0.0.1/styles.css \
  || die "Frontend Nginx failed to serve styles.css"
smoke_cleanup
trap 'rm -rf "$WORK"' EXIT
echo "Frontend image smoke test passed"
docker push "$REPO:$TAG"

echo "Planning targeted frontend task-definition update"
terraform plan -refresh=true -lock=true -input=false -no-color \
  -var-file=config/dev.tfvars \
  -var='deploy_application=true' \
  -var='start_application_services=true' \
  -var="frontend_image_tag=$TAG" \
  -target=aws_ecs_task_definition.frontend \
  -out="$WORK/frontend.tfplan"
terraform show -json "$WORK/frontend.tfplan" > "$WORK/frontend.json"

# Refuse ANY change outside replacing the frontend task definition.
jq -e '
  [.resource_changes[]
    | select(.mode == "managed" and .change.actions != ["no-op"])
    | {address, actions: .change.actions}
  ] as $changes
  | ($changes | length) == 1
    and $changes[0].address == "aws_ecs_task_definition.frontend"
    and (
      $changes[0].actions == ["delete", "create"] or
      $changes[0].actions == ["create", "delete"]
    )
' "$WORK/frontend.json" >/dev/null || die "Blocked: Terraform plan includes changes beyond a frontend task revision"

echo "Guard passed; applying ONLY frontend task revision"
terraform apply -input=false -no-color "$WORK/frontend.tfplan"
NEW_TASK="$(terraform output -raw frontend_task_definition_arn)"
[[ "$NEW_TASK" != "$OLD_TASK" && "$NEW_TASK" == arn:aws:ecs:"$AWS_REGION":"$ACCOUNT":task-definition/* ]] || die "New frontend task definition not found"

echo "Updating ONLY ECS service $SERVICE"
echo "Previous frontend revision (rollback reference): $OLD_TASK"
aws ecs update-service --region "$AWS_REGION" --cluster "$CLUSTER" \
  --service "$SERVICE" --task-definition "$NEW_TASK" >/dev/null
aws ecs wait services-stable --region "$AWS_REGION" --cluster "$CLUSTER" --services "$SERVICE"

read -r DESIRED RUNNING PENDING <<< "$(aws ecs describe-services \
  --region "$AWS_REGION" --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text)"
[[ "$DESIRED" -gt 0 && "$RUNNING" == "$DESIRED" && "$PENDING" == 0 ]] || die "Frontend has not reached desired ECS task count"

HTML="$(curl --fail --silent --show-error --retry 5 --retry-delay 3 "${BASE%/}/")"
grep -Fq 'id="apiStatus"' <<< "$HTML" || die "ALB is not serving the new frontend UI yet"
curl -fsS "${BASE%/}/api/health" | jq -e '.status == "ok" and .service == "backend"' >/dev/null
curl -fsS "${BASE%/}/api/health/db" | jq -e '.status == "ok" and .database == "reachable"' >/dev/null

printf '\nFrontend-only deployment verified.\nURL: %s\nECS frontend: %s/%s running (pending %s)\nBackend/monitoring/RDS unchanged.\n' "$BASE" "$RUNNING" "$DESIRED" "$PENDING"
