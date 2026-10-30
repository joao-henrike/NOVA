#!/usr/bin/env bash
set -euo pipefail

: "${AWS_REGION:?AWS_REGION must be set before activating ECS services.}"

command -v terraform >/dev/null 2>&1 || {
  echo "Terraform is required to read deployment outputs." >&2
  exit 1
}
command -v aws >/dev/null 2>&1 || {
  echo "AWS CLI is required to activate ECS services." >&2
  exit 1
}

cluster="$(terraform output -raw ecs_cluster_name)"
frontend_service="$(terraform output -raw frontend_ecs_service_name)"
backend_service="$(terraform output -raw backend_ecs_service_name)"
monitoring_service="$(terraform output -raw monitoring_ecs_service_name)"

activate_service() {
  local component="$1"
  local service task_definition desired_count min_capacity max_capacity current_desired_count

  service="$(terraform output -raw "${component}_ecs_service_name")"
  task_definition="$(terraform output -raw "${component}_task_definition_arn")"
  desired_count="$(terraform output -raw "${component}_desired_task_count")"
  min_capacity="$(terraform output -raw "${component}_min_task_count")"
  max_capacity="$(terraform output -raw "${component}_max_task_count")"
  current_desired_count="$(aws ecs describe-services \
    --cluster "$cluster" \
    --services "$service" \
    --region "$AWS_REGION" \
    --query 'services[0].desiredCount' \
    --output text)"

  if [[ ! "$current_desired_count" =~ ^[0-9]+$ ]]; then
    echo "Could not determine the current desired count for $service." >&2
    return 1
  fi
  if [ "$current_desired_count" -gt 0 ]; then
    desired_count="$current_desired_count"
    echo "Preserving $component desired count at $desired_count."
  else
    echo "Starting $component with configured initial desired count $desired_count."
  fi

  echo "Activating ${component} service after database migrations."
  aws ecs update-service \
    --cluster "$cluster" \
    --service "$service" \
    --task-definition "$task_definition" \
    --desired-count "$desired_count" \
    --region "$AWS_REGION" >/dev/null

  aws application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --resource-id "service/$cluster/$service" \
    --scalable-dimension ecs:service:DesiredCount \
    --min-capacity "$min_capacity" \
    --max-capacity "$max_capacity" \
    --region "$AWS_REGION" >/dev/null
}

activate_service frontend
activate_service backend

echo "Waiting for the application and monitoring services to stabilize."
aws ecs wait services-stable \
  --cluster "$cluster" \
  --services "$frontend_service" "$backend_service" "$monitoring_service" \
  --region "$AWS_REGION"

verify_service_task_definition() {
  local component="$1"
  local service expected actual

  service="$(terraform output -raw "${component}_ecs_service_name")"
  expected="$(terraform output -raw "${component}_task_definition_arn")"
  actual="$(aws ecs describe-services \
    --cluster "$cluster" \
    --services "$service" \
    --region "$AWS_REGION" \
    --query 'services[0].taskDefinition' \
    --output text)"

  if [ "$actual" != "$expected" ]; then
    echo "ECS rolled back or failed to retain the requested $component task definition." >&2
    echo "Expected: $expected" >&2
    echo "Actual:   $actual" >&2
    return 1
  fi
}

verify_service_task_definition frontend
verify_service_task_definition backend
echo "Frontend/backend task revisions are active and ECS services are stable."
