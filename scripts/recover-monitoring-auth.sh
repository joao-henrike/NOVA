#!/usr/bin/env bash
# NOVA monitoring-only recovery for ECS service cloudstart-dev-monitoring.
# Usage: bash scripts/recover-monitoring-auth.sh auto|deploy|reset-admin|status
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ -f config/dev.env ]] || { echo 'Missing config/dev.env' >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source config/dev.env
set +a
export AWS_PAGER="" AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
export PATH="$ROOT/.tools/bin:$PATH"
export TF_DATA_DIR="${TF_DATA_DIR:-/tmp/nova-terraform-data}"

MODE="${1:-}"
REGION="us-east-1"
ACCOUNT="996560371158"
CLUSTER="cloudstart-dev-cluster"
SERVICE="cloudstart-dev-monitoring"
DB="cloudstart-dev-monitoring-db"
SECRET="cloudstart-dev/monitoring/grafana-admin"
LOG_GROUP="/ecs/cloudstart-dev/monitoring"
LOCAL_SECRET="$ROOT/.deploy/grafana-admin-password"

fail() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
for bin in aws jq python3 curl; do command -v "$bin" >/dev/null || fail "$bin is missing"; done
[[ "${AWS_REGION:-}" == "$REGION" ]] || fail "Unexpected AWS region"
[[ "${EXPECTED_AWS_ACCOUNT_ID:-}" == "$ACCOUNT" ]] || fail "Local configuration points to another AWS account"
[[ "${TF_STATE_BUCKET:-}" == "cloudstart-nova-terraform-state-$ACCOUNT" ]] || fail "Unexpected Terraform state bucket"
[[ "${TF_STATE_KEY:-}" == "cloudstart/dev/terraform.tfstate" ]] || fail "Unexpected Terraform state key"
[[ "$(aws sts get-caller-identity --query Account --output text --region "$REGION")" == "$ACCOUNT" ]] || fail "AWS active account mismatch"
[[ "$(aws rds describe-db-instances --db-instance-identifier "$DB" --region "$REGION" --query 'DBInstances[0].DBInstanceStatus' --output text)" == available ]] || fail 'Monitoring RDS must be available'

status() {
  info 'Monitoring ECS current state'
  aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
    --query 'services[0].{Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount,TaskDefinition:taskDefinition,Events:events[:4].[createdAt,message]}' --output json
  info 'Grafana ALB response'
  local base="http://cloudstart-dev-alb-348899052.us-east-1.elb.amazonaws.com"
  curl -sS -o /dev/null --connect-timeout 5 --max-time 12 -w 'Grafana health HTTP %{http_code}\n' "$base/grafana/api/health" || true
}

sync_secret() {
  mkdir -p "$ROOT/.deploy/monitoring-recovery"
  chmod 700 "$ROOT/.deploy" "$ROOT/.deploy/monitoring-recovery"
  # Download the existing AWS secret privately; preserve any divergent local value.
  python3 - "$LOCAL_SECRET" "$ROOT/.deploy/monitoring-recovery" "$SECRET" "$REGION" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, time
path = pathlib.Path(sys.argv[1]); backup = pathlib.Path(sys.argv[2]); secret_id = sys.argv[3]; region = sys.argv[4]
value = subprocess.check_output(['aws','secretsmanager','get-secret-value','--secret-id',secret_id,
                                 '--region',region,'--query','SecretString','--output','text'], text=True)
password = json.loads(value).get('password')
if not isinstance(password,str) or len(password)<12:
    raise SystemExit('AWS Grafana secret is not a valid 12+ character password')
if path.exists():
    old = path.read_text()
    if old != password:
        target=backup / ('grafana-admin-password.old-local.' + time.strftime('%Y%m%dT%H%M%SZ',time.gmtime()))
        shutil.copyfile(path,target)
        target.chmod(0o600)
        print('Local differing secret backed up privately in .deploy/monitoring-recovery/')
if not path.exists() or path.read_text()!=password:
    tmp = path.with_name(path.name+'.tmp-recovery')
    tmp.write_text(password)
    tmp.chmod(0o600)
    os.replace(tmp,path)
path.chmod(0o600)
print('Local secret now matches AWS AWSCURRENT (password not displayed).')
PY
}

deploy() {
  command -v terraform >/dev/null || fail 'Terraform is missing; use the NOVA .tools/bin binary'
  command -v git >/dev/null || fail 'Git is missing'
  [[ "$(git branch --show-current)" == main ]] || fail 'Use branch main'
  git diff --quiet && git diff --cached --quiet || fail 'Commit/stash tracked local changes first'
  grep -Fq 'a password rotation must not reuse' monitoring/bootstrap.py || fail 'Missing fixed monitoring/bootstrap.py; update main first'
  sync_secret
  export TF_VAR_grafana_admin_password="$(cat "$LOCAL_SECRET")"
  info 'Initializing existing Terraform state (no infrastructure creation)'
  terraform init -reconfigure -input=false -no-color \
    -backend-config="bucket=$TF_STATE_BUCKET" \
    -backend-config="key=$TF_STATE_KEY" \
    -backend-config="region=$REGION"
  [[ "$(terraform output -raw aws_account_id)" == "$ACCOUNT" ]] || fail 'Terraform state account mismatch'

  local work; work="$(mktemp -d /tmp/nova-mon-only.XXXXXXXX)"
  trap 'rm -rf "$work"' EXIT
  info 'Planning ONE change: monitoring task-definition revision'
  terraform plan -refresh=true -lock=true -input=false -no-color \
    -var-file=config/dev.tfvars \
    -var='deploy_application=true' -var='start_application_services=true' \
    -target=aws_ecs_task_definition.monitoring \
    -out="$work/monitoring.tfplan"
  terraform show -json "$work/monitoring.tfplan" > "$work/plan.json"
  jq -e '
    [.resource_changes[]?
     | select(.mode == "managed" and .change.actions != ["no-op"])
     | {address, actions:.change.actions}] as $c
    | ($c|length)==1 and $c[0].address=="aws_ecs_task_definition.monitoring"
      and ($c[0].actions|index("create"))!=null
      and ($c[0].actions|index("delete"))!=null
  ' "$work/plan.json" >/dev/null || fail 'Plan includes other resources or no safe monitoring task replacement; nothing applied'

  info 'Applying ONLY the monitoring task-definition replacement'
  terraform apply -input=false -no-color "$work/monitoring.tfplan"
  local new old
  new="$(terraform state pull | jq -r '.resources[] | select(.mode=="managed" and .type=="aws_ecs_task_definition" and .name=="monitoring") | .instances[0].attributes.arn')"
  [[ "$new" == arn:aws:ecs:"$REGION":"$ACCOUNT":task-definition/cloudstart-dev-monitoring:* ]] || fail 'Unexpected monitoring task-definition ARN'
  old="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" --query 'services[0].taskDefinition' --output text)"
  info "Switching ONLY $SERVICE from ${old##*:} to ${new##*:}"
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$new" --desired-count 1 \
    --region "$REGION" --query 'service.{Name:serviceName,Task:taskDefinition,Desired:desiredCount}' --output json
  if ! aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION"; then
    status
    fail 'Monitoring deployment did not stabilize; inspect bootstrap logs before resetting any password'
  fi
  if ! verify_grafana; then
    status
    fail 'Service stabilized, but Grafana ALB endpoint did not pass health check'
  fi
  info 'Monitoring recovered without database password reset'
  status
}

verify_grafana() {
  local base="http://cloudstart-dev-alb-348899052.us-east-1.elb.amazonaws.com"
  local i response
  for i in $(seq 1 12); do
    response="$(curl -fsS --connect-timeout 5 --max-time 10 "$base/grafana/api/health" 2>/dev/null || true)"
    if printf '%s' "$response" | jq -e '.database=="ok"' >/dev/null 2>&1; then
      printf 'Grafana/API: database ok\n'; return 0
    fi
    sleep 5
  done
  return 1
}

reset_admin() {
  # This is the documented Zabbix 7.4 recovery of one Admin password, and only
  # after taking a completed RDS snapshot. No infrastructure or tables dropped.
  [[ -f "$LOCAL_SECRET" ]] || fail 'First run deploy to synchronize the AWS Grafana secret'
  command -v git >/dev/null || fail 'Git missing'
  python3 - "$LOCAL_SECRET" "$SECRET" "$REGION" <<'CHECK_SECRET_PY'
import json, pathlib, subprocess, sys
saved = pathlib.Path(sys.argv[1]).read_text()
remote = subprocess.check_output(['aws','secretsmanager','get-secret-value','--secret-id',sys.argv[2],
                                  '--region',sys.argv[3],'--query','SecretString','--output','text'],text=True)
if saved != json.loads(remote).get('password'):
    raise SystemExit('Local/AWS secret divergence detected: rerun deploy before reset-admin')
CHECK_SECRET_PY
  grep -Fq 'a password rotation must not reuse' monitoring/bootstrap.py || fail 'Fixed bootstrap must be present before password recovery'
  info 'WARNING: resetting ONLY the Zabbix Admin user to its official temporary default'
  info 'After the reset, the corrected bootstrap will rotate it to the AWS-derived strong password'
  local db_owner db_host db_secret task_def exec_role current_def network_json
  db_owner="$(aws rds describe-db-instances --db-instance-identifier "$DB" --region "$REGION" --query 'DBInstances[0].MasterUsername' --output text)"
  [[ "$db_owner" == zabbix ]] || fail 'Unexpected monitoring RDS username'
  db_host="$(aws rds describe-db-instances --db-instance-identifier "$DB" --region "$REGION" --query 'DBInstances[0].Endpoint.Address' --output text)"
  db_secret="$(aws rds describe-db-instances --db-instance-identifier "$DB" --region "$REGION" --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)"
  [[ "$db_secret" == arn:aws:secretsmanager:"$REGION":"$ACCOUNT":secret:* ]] || fail 'RDS secret ARN missing'
  current_def="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" --query 'services[0].taskDefinition' --output text)"
  [[ "$current_def" == arn:aws:ecs:"$REGION":"$ACCOUNT":task-definition/cloudstart-dev-monitoring:* ]] || fail 'Unexpected monitoring task definition'
  # Only reset credentials after the live ECS service points at the corrected script.
  local expected_hash actual_hash
  expected_hash="$(sha256sum monitoring/bootstrap.py | cut -d ' ' -f 1)"
  actual_hash="$(aws ecs describe-task-definition --task-definition "$current_def" --region "$REGION" --output json \
    | jq -r '.taskDefinition.containerDefinitions[] | select(.name=="monitoring-bootstrap") | .environment[] | select(.name=="MONITOR_BOOTSTRAP_SCRIPT_B64") | .value' \
    | base64 -d | sha256sum | cut -d ' ' -f 1)"
  [[ "$actual_hash" == "$expected_hash" ]] || fail 'Live ECS task does not embed the fixed bootstrap; run deploy first'
  exec_role="$(aws ecs describe-task-definition --task-definition "$current_def" --region "$REGION" --query 'taskDefinition.executionRoleArn' --output text)"
  [[ "$exec_role" == arn:aws:iam::"$ACCOUNT":role/* ]] || fail 'Unexpected execution role ARN'
  local work; work="$(mktemp -d /tmp/nova-zabbix-reset.XXXXXXXX)"
  trap 'rm -rf "$work"' EXIT
  aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
    --query 'services[0].networkConfiguration' --output json > "$work/network.json"
  jq -e '.awsvpcConfiguration.subnets|length>0' "$work/network.json" >/dev/null || fail 'Missing private ECS networking settings'

  local snapshot="cloudstart-dev-mon-admin-$(date -u +%Y%m%d%H%M%S)"
  info "Creating RDS snapshot before Admin credential recovery: $snapshot"
  aws rds create-db-snapshot --db-instance-identifier "$DB" --db-snapshot-identifier "$snapshot" \
    --region "$REGION" --query 'DBSnapshot.{ID:DBSnapshotIdentifier,Status:Status}' --output json
  aws rds wait db-snapshot-available --db-snapshot-identifier "$snapshot" --region "$REGION" \
    || fail 'RDS snapshot not ready; Admin password NOT modified'
  info 'Stopping ONLY the already failing monitoring ECS service before resetting Admin'
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 --region "$REGION" >/dev/null
  aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
    || fail 'Monitoring did not reach 0/0; Admin password NOT modified'

  # Build short-lived one-container Fargate job. PGPASSWORD is injected directly
  # from the RDS-managed AWS secret, and never appears in this file or the CLI args.
  export RECOVERY_DB_HOST="$db_host" RECOVERY_DB_SECRET="$db_secret" RECOVERY_EXEC_ROLE="$exec_role"
  python3 - "$work/recovery.json" <<'PY'
import json, os, pathlib, sys
sql = '''BEGIN;
DO $$
BEGIN
 IF (SELECT count(*) FROM users WHERE username = 'Admin') <> 1 THEN
   RAISE EXCEPTION 'Expected exactly one Admin user';
 END IF;
END $$;
UPDATE users SET passwd = '$2a$10$ZXIvHAEP2ZM.dLXTm6uPHOMVlARXX7cqjbhM6Fn0cANzkCQBWpMrS' WHERE username = 'Admin';
COMMIT;
'''
obj={
  'family':'cloudstart-dev-monitoring-admin-recovery',
  'requiresCompatibilities':['FARGATE'],
  'networkMode':'awsvpc',
  'cpu':'256','memory':'512',
  'executionRoleArn':os.environ['RECOVERY_EXEC_ROLE'],
  'containerDefinitions':[{
    'name':'zabbix-admin-recovery',
    'image':'postgres:16-alpine',
    'essential':True,
    'entryPoint':['/bin/sh','-ec'],
    'command':["psql -X -v ON_ERROR_STOP=1 <<'SQL'\n"+sql+"SQL"],
    'environment':[
      {'name':'PGHOST','value':os.environ['RECOVERY_DB_HOST']},
      {'name':'PGPORT','value':'5432'},
      {'name':'PGUSER','value':'zabbix'},
      {'name':'PGDATABASE','value':'zabbix'},
      {'name':'PGSSLMODE','value':'require'},
    ],
    'secrets':[{'name':'PGPASSWORD','valueFrom':os.environ['RECOVERY_DB_SECRET']+':password::'}],
    'logConfiguration':{'logDriver':'awslogs','options':{
      'awslogs-group':'/ecs/cloudstart-dev/monitoring',
      'awslogs-region':'us-east-1',
      'awslogs-stream-prefix':'zabbix-admin-recovery',
    }},
  }],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(obj))
PY
  unset RECOVERY_DB_HOST RECOVERY_DB_SECRET RECOVERY_EXEC_ROLE
  local recovery_def task_id exit_code
  recovery_def="$(aws ecs register-task-definition --cli-input-json "file://$work/recovery.json" \
    --region "$REGION" --query 'taskDefinition.taskDefinitionArn' --output text)"
  [[ "$recovery_def" == arn:aws:ecs:"$REGION":"$ACCOUNT":task-definition/cloudstart-dev-monitoring-admin-recovery:* ]] || fail 'Temporary recovery task definition registration failed'
  info 'Running one-off internal SQL job in the existing monitoring VPC'
  aws ecs run-task --cluster "$CLUSTER" --task-definition "$recovery_def" --launch-type FARGATE \
    --network-configuration "file://$work/network.json" --region "$REGION" > "$work/run.json"
  jq -e '(.failures|length)==0 and (.tasks|length)==1' "$work/run.json" >/dev/null \
    || fail 'Fargate refused the recovery job; monitoring is still stopped at 0/0'
  task_id="$(jq -r '.tasks[0].taskArn' "$work/run.json")"
  aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$task_id" --region "$REGION" \
    || fail 'Recovery task did not stop; review AWS ECS task state'
  exit_code="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_id" --region "$REGION" \
    --query 'tasks[0].containers[0].exitCode' --output text)"
  [[ "$exit_code" == 0 ]] || {
    echo 'Recovery container logs (no passwords should be logged):' >&2
    aws logs tail "$LOG_GROUP" --since 20m --log-stream-name-prefix 'zabbix-admin-recovery/' --format short --region "$REGION" >&2 || true
    fail "Recovery SQL task returned exit $exit_code; monitoring remains stopped at 0/0"
  }
  info 'Admin reset complete; restarting ONLY monitoring with the corrected bootstrap'
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$current_def" --desired-count 1 \
    --region "$REGION" >/dev/null
  aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
    || fail 'Zabbix reset succeeded but monitoring did not stabilize; inspect bootstrap logs'
  verify_grafana || fail 'Zabbix reset succeeded but Grafana health is not OK'
  info "Monitoring restored; snapshot preserved as $snapshot"
  status
}

auto_recover() {
  # The recovery starts with a regular monitoring-only task deployment.
  # It may reset the Admin password only on fresh, specific authentication
  # failures and only after verifying the fixed script is deployed.
  local start_ms current expected_hash actual_hash errors
  start_ms="$(($(date -u +%s) * 1000))"
  info 'Auto recovery: try the corrected bootstrap first (no Zabbix database changes)'
  # Execute as a separate Bash process so set -e remains effective in deploy.
  if bash "$ROOT/scripts/recover-monitoring-auth.sh" deploy; then
    info 'Recovery succeeded without Zabbix Admin reset'
    return 0
  fi
  info 'The monitoring-only deployment failed; checking new authentication errors'
  current="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --region "$REGION" --query 'services[0].taskDefinition' --output text)"
  [[ "$current" == arn:aws:ecs:"$REGION":"$ACCOUNT":task-definition/cloudstart-dev-monitoring:* ]] \
    || fail 'Invalid monitoring ECS task revision; no reset performed'
  expected_hash="$(sha256sum monitoring/bootstrap.py | awk '{print $1}')"
  actual_hash="$(aws ecs describe-task-definition --task-definition "$current" --region "$REGION" --output json \
    | jq -r '.taskDefinition.containerDefinitions[] | select(.name=="monitoring-bootstrap") | .environment[] | select(.name=="MONITOR_BOOTSTRAP_SCRIPT_B64") | .value' \
    | base64 -d | sha256sum | awk '{print $1}')"
  [[ "$actual_hash" == "$expected_hash" ]] \
    || fail 'The running service does not reference the fixed bootstrap. Refusing to reset Admin.'
  errors="$(aws logs filter-log-events --log-group-name "$LOG_GROUP" \
    --start-time "$start_ms" \
    --filter-pattern '"MONITORING BOOTSTRAP FAILED"' \
    --region "$REGION" --query 'events[].message' --output text)"
  if grep -Fq 'Zabbix Admin credentials do not match the configured secret' <<< "$errors"; then
    info 'New Zabbix credential mismatch confirmed. Taking RDS snapshot before recovery.'
    reset_admin
  else
    fail 'No new, specific Zabbix Admin mismatch found. No database changes made. Check ECS events and bootstrap logs.'
  fi
}

case "$MODE" in
  auto) auto_recover ;;
  deploy) deploy ;;
  reset-admin) reset_admin ;;
  status) status ;;
  *) fail 'Use: bash scripts/recover-monitoring-auth.sh auto | deploy | reset-admin | status' ;;
esac