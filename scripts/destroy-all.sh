#!/usr/bin/env bash
# First-pass local destroy/audit pipeline for CloudStart/NOVA development.
# It destroys each configured Terraform state, stops this checkout's Compose
# stacks, then inventories AWS leftovers. It does not delete untracked AWS
# resources through direct service APIs; these are reported explicitly.
set -uo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CONFIG_ENV="$ROOT_DIR/config/dev.env"
[[ -f "$CONFIG_ENV" ]] || { echo "Missing $CONFIG_ENV" >&2; exit 2; }
# shellcheck disable=SC1091
source "$CONFIG_ENV"
: "${AWS_REGION:=us-east-1}"
: "${EXPECTED_AWS_ACCOUNT_ID:=}"
: "${TF_STATE_BUCKET:=}"
: "${TF_STATE_KEY:=cloudstart/dev/terraform.tfstate}"
: "${LEGACY_TF_STATE_KEYS:=}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""

INVENTORY_ONLY=false
if [[ "${1:-}" == "--inventory-only" ]]; then INVENTORY_ONLY=true
elif [[ $# -gt 0 ]]; then echo "Usage: $0 [--inventory-only]" >&2; exit 2; fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_DIR="$ROOT_DIR/.deploy/destroy-all-$STAMP"
WORK_DIR="$REPORT_DIR/work"
LOG_FILE="$REPORT_DIR/destroy-all.log"
RESULTS_FILE="$REPORT_DIR/results.tsv"
BEFORE_FILE="$REPORT_DIR/inventory-before.txt"
AFTER_FILE="$REPORT_DIR/inventory-after.txt"
mkdir -p "$WORK_DIR"
chmod 700 "$ROOT_DIR/.deploy" "$REPORT_DIR" "$WORK_DIR"
: > "$LOG_FILE"
printf 'step\tresult\texit_code\n' > "$RESULTS_FILE"
FAILED_STEPS=0

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG_FILE"; }
run_step() {
  local label="$1"; shift
  local rc
  log "START: $label"
  "$@" 2>&1 | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  if [[ "$rc" -eq 0 ]]; then
    printf '%s\tPASS\t0\n' "$label" >> "$RESULTS_FILE"
    log "PASS: $label"
  else
    printf '%s\tFAIL\t%s\n' "$label" "$rc" >> "$RESULTS_FILE"
    FAILED_STEPS=$((FAILED_STEPS + 1))
    log "FAIL: $label (exit=$rc); continuing."
  fi
  return "$rc"
}
for cmd in aws terraform jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not found: $cmd" >&2; exit 2; }
done
[[ -n "$EXPECTED_AWS_ACCOUNT_ID" && -n "$TF_STATE_BUCKET" ]] || { echo "Missing AWS account/bucket in config/dev.env" >&2; exit 2; }

IDENTITY="$(aws sts get-caller-identity --output json)" || { echo "AWS authentication failed." >&2; exit 2; }
ACTUAL_ACCOUNT="$(jq -r '.Account' <<< "$IDENTITY")"
CALLER_ARN="$(jq -r '.Arn' <<< "$IDENTITY")"
[[ "$ACTUAL_ACCOUNT" == "$EXPECTED_AWS_ACCOUNT_ID" ]] || { echo "AWS account mismatch: expected $EXPECTED_AWS_ACCOUNT_ID, got $ACTUAL_ACCOUNT." >&2; exit 2; }
aws s3api head-bucket --bucket "$TF_STATE_BUCKET" --region "$AWS_REGION" >/dev/null 2>&1 || { echo "Cannot access Terraform state bucket $TF_STATE_BUCKET." >&2; exit 2; }

log "Scope: cloudstart/dev, account=$ACTUAL_ACCOUNT region=$AWS_REGION caller=$CALLER_ARN"
log "Report directory: $REPORT_DIR"
log "Terraform backend bucket remains in place so a future deployment can use it."

inventory_aws() {
  local data
  echo "ACCOUNT=$ACTUAL_ACCOUNT REGION=$AWS_REGION PROJECT=cloudstart ENVIRONMENT=dev"
  echo "STATE_BUCKET_PRESERVED=$TF_STATE_BUCKET"
  echo "STATE_KEYS=$TF_STATE_KEY,${LEGACY_TF_STATE_KEYS}"
  echo
  echo "=== Tagged resources (Project=cloudstart, Environment=dev) ==="
  aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=cloudstart Key=Environment,Values=dev --resources-per-page 100 --output json 2>/dev/null |
    jq -r '.ResourceTagMappingList[]? | [.ResourceARN,((.Tags // [])|map(.Key+"="+.Value)|join(","))] | @tsv' || echo "[tag inventory query unavailable]"
  echo
  echo "=== ECS clusters/services/tasks ==="
  data="$(aws ecs list-clusters --output json 2>/dev/null || printf '{"clusterArns":[]}')"
  while IFS= read -r cluster; do
    [[ -n "$cluster" ]] || continue
    echo "CLUSTER $cluster"
    aws ecs list-services --cluster "$cluster" --output json 2>/dev/null | jq -r '.serviceArns[]? | "SERVICE "+.' || true
    aws ecs list-tasks --cluster "$cluster" --desired-status RUNNING --output json 2>/dev/null | jq -r '.taskArns[]? | "RUNNING_TASK "+.' || true
  done < <(jq -r '.clusterArns[]? | select(contains("cloudstart-dev"))' <<< "$data")
  echo
  echo "=== Load balancers and target groups ==="
  aws elbv2 describe-load-balancers --output json 2>/dev/null | jq -r '.LoadBalancers[]? | select(.LoadBalancerName|startswith("cloudstart-dev")) | [.LoadBalancerName,.LoadBalancerArn,.State.Code] | @tsv' || true
  aws elbv2 describe-target-groups --output json 2>/dev/null | jq -r '.TargetGroups[]? | select(.TargetGroupName|startswith("cloudstart-dev")) | [.TargetGroupName,.TargetGroupArn,.VpcId] | @tsv' || true
  echo
  echo "=== RDS / DB subnet groups / manual snapshots ==="
  aws rds describe-db-instances --output json 2>/dev/null | jq -r '.DBInstances[]? | select(.DBInstanceIdentifier|startswith("cloudstart-dev")) | [.DBInstanceIdentifier,.DBInstanceStatus] | @tsv' || true
  aws rds describe-db-clusters --output json 2>/dev/null | jq -r '.DBClusters[]? | select(.DBClusterIdentifier|startswith("cloudstart-dev")) | [.DBClusterIdentifier,.Status] | @tsv' || true
  aws rds describe-db-subnet-groups --output json 2>/dev/null | jq -r '.DBSubnetGroups[]? | select(.DBSubnetGroupName|startswith("cloudstart-dev")) | .DBSubnetGroupName' || true
  aws rds describe-db-snapshots --snapshot-type manual --output json 2>/dev/null | jq -r '.DBSnapshots[]? | select(.DBSnapshotIdentifier|startswith("cloudstart-dev")) | .DBSnapshotIdentifier' || true
  echo
  echo "=== ECR / Secrets Manager / IAM / logs ==="
  aws ecr describe-repositories --output json 2>/dev/null | jq -r '.repositories[]? | select(.repositoryName|startswith("cloudstart-dev")) | [.repositoryName,.repositoryArn] | @tsv' || true
  aws secretsmanager list-secrets --output json 2>/dev/null | jq -r '.SecretList[]? | select((.Name|startswith("cloudstart-dev/")) or (.Name|startswith("cloudstart-dev-"))) | [.Name,.ARN] | @tsv' || true
  aws iam list-roles --output json 2>/dev/null | jq -r '.Roles[]? | select(.RoleName|startswith("cloudstart-dev-")) | [.RoleName,.Arn] | @tsv' || true
  aws logs describe-log-groups --output json 2>/dev/null | jq -r '.logGroups[]? | select((.logGroupName|startswith("/ecs/cloudstart-dev")) or (.logGroupName|startswith("cloudstart-dev"))) | [.logGroupName,(.storedBytes // 0)] | @tsv' || true
  echo
  echo "=== VPCs / NAT / subnets / ENIs ==="
  data="$(aws ec2 describe-vpcs --output json 2>/dev/null || printf '{"Vpcs":[]}')"
  jq -r '.Vpcs[]? | select((any(.Tags[]?;.Key=="Project" and .Value=="cloudstart") and any(.Tags[]?;.Key=="Environment" and .Value=="dev")) or any(.Tags[]?;.Key=="Name" and (.Value|startswith("cloudstart-dev"))) | [.VpcId,.CidrBlock] | @tsv' <<< "$data"
  while IFS= read -r vpc; do
    [[ -n "$vpc" ]] || continue
    aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" --output json 2>/dev/null | jq -r '.NatGateways[]? | select(.State!="deleted" and .State!="failed") | ["NAT",.NatGatewayId,.State] | @tsv' || true
    aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --output json 2>/dev/null | jq -r '.Subnets[]? | ["SUBNET",.SubnetId,.CidrBlock] | @tsv' || true
    aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" --output json 2>/dev/null | jq -r '.NetworkInterfaces[]? | ["ENI",.NetworkInterfaceId,.Status,(.Description//"")] | @tsv' || true
  done < <(jq -r '.Vpcs[]? | select((any(.Tags[]?;.Key=="Project" and .Value=="cloudstart") and any(.Tags[]?;.Key=="Environment" and .Value=="dev")) or any(.Tags[]?;.Key=="Name" and (.Value|startswith("cloudstart-dev"))) | .VpcId' <<< "$data")
  echo
  echo "=== Local Docker Compose ==="
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker compose -f docker-compose.yml ps -a 2>&1 || true
    docker compose -f docker-compose.monitoring.yml ps -a 2>&1 || true
    docker ps -a --filter "label=com.docker.compose.project.working_dir=$ROOT_DIR" --format 'CONTAINER {{.ID}} {{.Names}} {{.Status}}' 2>&1 || true
  else echo "Docker daemon unavailable."; fi
}

if [[ "$INVENTORY_ONLY" == true ]]; then
  log "Inventory-only mode; no deletion."
  inventory_aws | tee "$BEFORE_FILE"
  echo "Inventory saved to $BEFORE_FILE"
  exit 0
fi

cat <<EOF

DESTRUCTIVE OPERATION — CLOUDSTART/NOVA DEV
Account: $ACTUAL_ACCOUNT
Region : $AWS_REGION
Will run Terraform destroy for all configured states and remove the local
Compose stacks/volumes in this checkout. The Terraform state bucket is kept.
EOF
CONFIRM="DESTROY cloudstart $ACTUAL_ACCOUNT $AWS_REGION"
read -r -p "Type exactly '$CONFIRM' to continue: " answer
[[ "$answer" == "$CONFIRM" ]] || { log "Confirmation mismatch; no deletion performed."; exit 2; }

log "Stage 0: pre-destroy inventory."
inventory_aws | tee "$BEFORE_FILE"
TF_VAR_grafana_admin_password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
export TF_VAR_grafana_admin_password TF_PLUGIN_CACHE_DIR="$REPORT_DIR/plugin-cache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"
printf 'plugin_cache_dir = "%s"\n' "$TF_PLUGIN_CACHE_DIR" > "$REPORT_DIR/terraformrc"
export TF_CLI_CONFIG_FILE="$REPORT_DIR/terraformrc"

declare -a STATE_KEYS=("$TF_STATE_KEY")
if [[ -n "$LEGACY_TF_STATE_KEYS" ]]; then
  IFS=',' read -r -a LEGACY_KEYS <<< "$LEGACY_TF_STATE_KEYS"
  for key in "${LEGACY_KEYS[@]}"; do
    [[ -n "$key" ]] || continue
    found=false
    for existing in "${STATE_KEYS[@]}"; do [[ "$existing" == "$key" ]] && found=true; done
    [[ "$found" == true ]] || STATE_KEYS+=("$key")
  done
fi

log "Stage 1: Terraform destroy across current and legacy states."
idx=0
for key in "${STATE_KEYS[@]}"; do
  idx=$((idx + 1))
  err="$WORK_DIR/state-$idx.err"
  if aws s3api head-object --bucket "$TF_STATE_BUCKET" --key "$key" --region "$AWS_REGION" >/dev/null 2>"$err"; then
    safe_key="$(printf '%s' "$key" | tr '/:' '__')"
    data_dir="$WORK_DIR/tfdata-$safe_key"
    mkdir -p "$data_dir"
    if run_step "terraform_init_$idx" env TF_DATA_DIR="$data_dir" terraform init -backend-config="bucket=$TF_STATE_BUCKET" -backend-config="region=$AWS_REGION" -backend-config="key=$key" -reconfigure -input=false -no-color; then
      run_step "terraform_destroy_$idx" env TF_DATA_DIR="$data_dir" terraform destroy -var-file=config/dev.tfvars -var='deploy_application=false' -input=false -auto-approve -lock-timeout=5m -no-color || true
    fi
  elif grep -Eqi '404|Not Found|NoSuchKey|not found' "$err"; then
    log "No current state object at $key; skipping."
  else
    run_step "state_inspection_$idx" cat "$err" || true
  fi
done

log "Stage 2: local Docker Compose teardown."
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  run_step "local_application_compose_down" docker compose -f docker-compose.yml down --volumes --remove-orphans || true
  run_step "local_monitoring_compose_down" docker compose -f docker-compose.monitoring.yml down --volumes --remove-orphans || true
  containers="$(docker ps -aq --filter "label=com.docker.compose.project.working_dir=$ROOT_DIR" 2>/dev/null || true)"
  [[ -z "$containers" ]] || run_step "remove_repo_containers" docker rm -f $containers || true
  networks="$(docker network ls -q --filter "label=com.docker.compose.project.working_dir=$ROOT_DIR" 2>/dev/null || true)"
  [[ -z "$networks" ]] || run_step "remove_repo_networks" docker network rm $networks || true
  volumes="$(docker volume ls -q --filter "label=com.docker.compose.project.working_dir=$ROOT_DIR" 2>/dev/null || true)"
  [[ -z "$volumes" ]] || run_step "remove_repo_volumes" docker volume rm $volumes || true
else
  log "Docker daemon unavailable; local Docker cleanup skipped."
fi

log "Stage 3: independent AWS post-destroy inventory."
inventory_aws | tee "$AFTER_FILE"

scope_resources() {
  local data
  data="$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=cloudstart Key=Environment,Values=dev --resources-per-page 100 --output json)" || return 1
  jq -r '.ResourceTagMappingList[]?.ResourceARN' <<< "$data"
  data="$(aws ecs list-clusters --output json)" || return 1
  jq -r '.clusterArns[]? | select(contains("cloudstart-dev"))' <<< "$data"
  data="$(aws elbv2 describe-load-balancers --output json)" || return 1
  jq -r '.LoadBalancers[]? | select(.LoadBalancerName|startswith("cloudstart-dev")) | .LoadBalancerArn' <<< "$data"
  data="$(aws elbv2 describe-target-groups --output json)" || return 1
  jq -r '.TargetGroups[]? | select(.TargetGroupName|startswith("cloudstart-dev")) | .TargetGroupArn' <<< "$data"
  data="$(aws rds describe-db-instances --output json)" || return 1
  jq -r '.DBInstances[]? | select(.DBInstanceIdentifier|startswith("cloudstart-dev")) | .DBInstanceIdentifier' <<< "$data"
  data="$(aws rds describe-db-clusters --output json)" || return 1
  jq -r '.DBClusters[]? | select(.DBClusterIdentifier|startswith("cloudstart-dev")) | .DBClusterIdentifier' <<< "$data"
  data="$(aws rds describe-db-subnet-groups --output json)" || return 1
  jq -r '.DBSubnetGroups[]? | select(.DBSubnetGroupName|startswith("cloudstart-dev")) | .DBSubnetGroupName' <<< "$data"
  data="$(aws ecr describe-repositories --output json)" || return 1
  jq -r '.repositories[]? | select(.repositoryName|startswith("cloudstart-dev")) | .repositoryArn' <<< "$data"
  data="$(aws secretsmanager list-secrets --output json)" || return 1
  jq -r '.SecretList[]? | select((.Name|startswith("cloudstart-dev/")) or (.Name|startswith("cloudstart-dev-"))) | .ARN' <<< "$data"
  data="$(aws iam list-roles --output json)" || return 1
  jq -r '.Roles[]? | select(.RoleName|startswith("cloudstart-dev-")) | .Arn' <<< "$data"
  data="$(aws logs describe-log-groups --output json)" || return 1
  jq -r '.logGroups[]? | select((.logGroupName|startswith("/ecs/cloudstart-dev")) or (.logGroupName|startswith("cloudstart-dev"))) | .logGroupName' <<< "$data"
  data="$(aws ec2 describe-vpcs --output json)" || return 1
  jq -r '.Vpcs[]? | select((any(.Tags[]?;.Key=="Project" and .Value=="cloudstart") and any(.Tags[]?;.Key=="Environment" and .Value=="dev")) or any(.Tags[]?;.Key=="Name" and (.Value|startswith("cloudstart-dev"))) | .VpcId' <<< "$data"
  data="$(aws ec2 describe-addresses --output json)" || return 1
  jq -r '.Addresses[]? | select(any(.Tags[]?;.Key=="Name" and (.Value|startswith("cloudstart-dev-nat-eip"))) or (any(.Tags[]?;.Key=="Project" and .Value=="cloudstart") and any(.Tags[]?;.Key=="Environment" and .Value=="dev"))) | .AllocationId' <<< "$data"
}
if scope_resources > "$WORK_DIR/remaining-raw.txt"; then
  sort -u "$WORK_DIR/remaining-raw.txt" > "$WORK_DIR/remaining.txt"
  INVENTORY_COMPLETE=true
  REMAINING_COUNT="$(grep -cve '^$' "$WORK_DIR/remaining.txt" || true)"
else
  log "A final inventory API failed."
fi

log "FINAL: failed_steps=$FAILED_STEPS remaining_scoped_resources=$REMAINING_COUNT inventory_complete=$INVENTORY_COMPLETE"
log "Before: $BEFORE_FILE"
log "After: $AFTER_FILE"
log "Log: $LOG_FILE"
log "Results: $RESULTS_FILE"
if [[ "$INVENTORY_COMPLETE" != true || "$REMAINING_COUNT" -ne 0 || "$FAILED_STEPS" -ne 0 ]]; then
  echo
  echo "DESTROY/AUDIT INCOMPLETE: AWS resources outside known Terraform states may remain."
  [[ -f "$WORK_DIR/remaining.txt" ]] && cat "$WORK_DIR/remaining.txt"
  echo "Review report: $REPORT_DIR"
  exit 1
fi
echo
echo "Terraform-managed resources were destroyed, local Compose stacks were removed, and the AWS post-scan found no scoped tagged/name-matched leftovers."
echo "Report: $REPORT_DIR"
