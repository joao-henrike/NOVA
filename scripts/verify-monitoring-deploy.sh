#!/usr/bin/env bash
# Read-only AWS verification of the actual service revision and collection.
set -euo pipefail
export AWS_PAGER=""
: "${AWS_REGION:?AWS_REGION must be set}"
cluster="$(terraform output -raw ecs_cluster_name)"
service="$(terraform output -raw monitoring_ecs_service_name)"
expected="$(terraform output -raw monitoring_task_definition_arn)"
fail() { printf 'MONITORING FAIL: %s\n' "$*" >&2; exit 1; }
log_group="/ecs/${service%-monitoring}/monitoring"
for ((attempt=1; attempt<=60; attempt++)); do
  svc="$(aws ecs describe-services --cluster "$cluster" --services "$service" --region "$AWS_REGION" --output json)"
  actual="$(jq -r '.services[0].taskDefinition // empty' <<< "$svc")"
  [ "$actual" = "$expected" ] || fail "ECS rolled back or retained a different task revision: $actual"
  if ! jq -e '.services[0] | .desiredCount == 1 and .runningCount == 1 and .pendingCount == 0 and (.deployments | length) == 1 and .deployments[0].rolloutState == "COMPLETED"' <<< "$svc" >/dev/null; then
    sleep 10
    continue
  fi
  task="$(aws ecs list-tasks --cluster "$cluster" --service-name "$service" --desired-status RUNNING --region "$AWS_REGION" --query 'taskArns[0]' --output text)"
  if [ -z "$task" ] || [ "$task" = "None" ]; then sleep 10; continue; fi
  details="$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task" --region "$AWS_REGION" --output json)"
  if ! jq -e --arg expected "$expected" '.tasks[0] | .taskDefinitionArn == $expected and .lastStatus == "RUNNING" and
    any(.containers[]; .name == "grafana-db-init" and .lastStatus == "STOPPED" and .exitCode == 0) and
    any(.containers[]; .name == "grafana" and .healthStatus == "HEALTHY") and
    any(.containers[]; .name == "monitoring-bootstrap" and .healthStatus == "HEALTHY")' <<< "$details" >/dev/null; then
    sleep 10
    continue
  fi
  task_id="${task##*/}"
  stream="monitoring-bootstrap/monitoring-bootstrap/$task_id"
  if events="$(aws logs filter-log-events --log-group-name "$log_group" --log-stream-names "$stream" --filter-pattern '"NOVA monitoring verification passed"' --region "$AWS_REGION" --output json 2>/dev/null)" &&
    jq -e '.events | length > 0' <<< "$events" >/dev/null; then
    echo "MONITORING PASS: expected revision, PostgreSQL init, healthy Grafana and successful collector cycle."
    exit 0
  fi
  sleep 10
done
fail "Monitoring did not pass runtime checks; inspect ECS and CloudWatch logs."
