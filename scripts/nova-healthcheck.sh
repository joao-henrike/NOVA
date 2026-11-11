#!/usr/bin/env bash
# NOVA / CloudStart AWS operational health audit.
# READ ONLY: no AWS mutations, no Terraform, no restarts, no credentials printed.
# Exit: 0 = no failures, 1 = at least one failed check, 2 = preflight error.
set -uo pipefail
export AWS_PAGER="" PAGER=cat AWS_DEFAULT_REGION="us-east-1"

REGION="${NOVA_REGION:-us-east-1}"
ACCOUNT="996560371158"
BASE_NAME="cloudstart-dev"
CLUSTER="${BASE_NAME}-cluster"
ALB_NAME="${BASE_NAME}-alb"
LOG_GROUP="/ecs/${BASE_NAME}/monitoring"
PASS=0; WARN=0; FAIL=0

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  printf 'Uso: bash nova-healthcheck.sh\nValida ECS, containers, ALB, HTTP, RDS, VPC, NAT, CloudWatch e ECR (somente leitura).\n'
  exit 0
fi
if [[ $# -ne 0 ]]; then printf 'Argumento desconhecido: %s\n' "$1" >&2; exit 2; fi

for bin in aws jq curl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf 'ERRO: dependencia ausente: %s\n' "$bin" >&2; exit 2
  fi
done

# The fixed account check prevents accidentally evaluating another AWS account.
CALLER="$(aws sts get-caller-identity --region "$REGION" --query Account --output text --no-cli-pager 2>/dev/null)" || {
  printf 'ERRO: sem permissao para consultar a identidade AWS.\n' >&2; exit 2;
}
if [[ "$CALLER" != "$ACCOUNT" ]]; then
  printf 'ERRO: conta AWS diferente. Esperada=%s, atual=%s. Abortando.\n' "$ACCOUNT" "$CALLER" >&2
  exit 2
fi

say() { printf '[%-4s] %-45s %s\n' "$1" "$2" "${3:-}"; }
ok() { PASS=$((PASS+1)); say PASS "$1" "${2:-}"; }
warn() { WARN=$((WARN+1)); say WARN "$1" "${2:-}"; }
bad() { FAIL=$((FAIL+1)); say FAIL "$1" "${2:-}"; }
section() { printf '\n===== %s =====\n' "$1"; }
aws_json() { aws "$@" --region "$REGION" --output json --no-cli-pager 2>/dev/null; }

printf '\nNOVA | AUDITORIA OPERACIONAL AWS (SOMENTE LEITURA)\n'
printf 'Data UTC: %s | Conta: %s | Regiao: %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S')" "$ACCOUNT" "$REGION"
section 'IDENTIDADE E CLUSTER'
ok 'Conta AWS' "$ACCOUNT"
cluster_json="$(aws_json ecs describe-clusters --clusters "$CLUSTER")" || cluster_json=''
if [[ -z "$cluster_json" ]] || ! jq -e --arg name "$CLUSTER" '.clusters[]? | select(.clusterName==$name and .status=="ACTIVE")' <<<"$cluster_json" >/dev/null 2>&1; then
  bad 'Cluster ECS' 'Nao encontrado / nao ACTIVE / falha na consulta'
else
  ok 'Cluster ECS' "$CLUSTER ACTIVE"
fi

section 'SERVICOS E CONTAINERS ECS'
services_json="$(aws_json ecs describe-services --cluster "$CLUSTER" --services "${BASE_NAME}-frontend" "${BASE_NAME}-backend" "${BASE_NAME}-monitoring")" || services_json=''

for item in 'frontend:2' 'backend:2' 'monitoring:1'; do
  name="${item%%:*}"; expected="${item##*:}"; service="${BASE_NAME}-${name}"
  if [[ -z "$services_json" ]]; then
    bad "ECS $name" 'Falha ao consultar servicos'
    continue
  fi
  srv="$(jq -c --arg n "$service" '.services[]? | select(.serviceName==$n)' <<<"$services_json" 2>/dev/null)"
  if [[ -z "$srv" ]]; then bad "ECS $name" 'Servico nao encontrado'; continue; fi
  status="$(jq -r '.status // "?"' <<<"$srv")"
  desired="$(jq -r '.desiredCount // 0' <<<"$srv")"
  running="$(jq -r '.runningCount // 0' <<<"$srv")"
  pending="$(jq -r '.pendingCount // 0' <<<"$srv")"
  def="$(jq -r '.taskDefinition // ""' <<<"$srv")"
  if [[ "$status" == ACTIVE && "$running" == "$desired" && "$pending" == 0 && "$desired" == "$expected" ]]; then
    ok "ECS $name" "RUNNING $running/$desired | pending=$pending | task=${def##*:}"
  elif [[ "$status" != ACTIVE || "$desired" == 0 || "$running" == 0 ]]; then
    bad "ECS $name" "status=$status running=$running/$desired pending=$pending esperado=$expected"
  else
    warn "ECS $name" "status=$status running=$running/$desired pending=$pending esperado=$expected"
  fi
  # Services during a rolling deployment can report the expected number of
  # running tasks before the deployment has stabilized.
  if jq -e '([.deployments[]? | select(.status=="PRIMARY" and .rolloutState=="COMPLETED")] | length)==1 and ([.deployments[]? | select(.status!="PRIMARY")] | length)==0' <<<"$srv" >/dev/null 2>&1; then
    ok "Deploy ECS $name" 'PRIMARY COMPLETED, sem deploy paralelo'
  else
    warn "Deploy ECS $name" 'Rollout em andamento / nao confirmado'
  fi
  arns="$(aws_json ecs list-tasks --cluster "$CLUSTER" --service-name "$service" --desired-status RUNNING)" || arns=''
  if [[ -z "$arns" ]]; then bad "Tasks $name" 'Erro ao listar tarefas'; continue; fi
  task_count="$(jq -r '.taskArns | length' <<<"$arns" 2>/dev/null)"
  if [[ ! "$task_count" =~ ^[0-9]+$ || "$task_count" -eq 0 ]]; then
    bad "Tasks $name" 'Nenhuma tarefa RUNNING encontrada'
    continue
  fi
  mapfile -t task_list < <(jq -r '.taskArns[]' <<<"$arns")
  tasks_json="$(aws_json ecs describe-tasks --cluster "$CLUSTER" --tasks "${task_list[@]}")" || tasks_json=''
  if [[ -z "$tasks_json" ]]; then bad "Containers $name" 'Erro em describe-tasks'; continue; fi
  # Only call UNKNOWN a failure if the container has an explicit healthcheck.
  taskdef_json="$(aws_json ecs describe-task-definition --task-definition "$def")" || taskdef_json=''
  while IFS=$'\t' read -r task_id task_status task_health; do
    [[ -n "$task_id" ]] || continue
    if [[ "$task_status" != RUNNING ]]; then
      bad "Task $name/$task_id" "$task_status"
    elif [[ "$task_health" == UNHEALTHY ]]; then
      bad "Task $name/$task_id" 'UNHEALTHY'
    elif [[ "$task_health" == HEALTHY ]]; then
      ok "Task $name/$task_id" 'RUNNING / HEALTHY'
    else
      warn "Task $name/$task_id" "RUNNING / health=$task_health"
    fi
  done < <(jq -r '.tasks[]? | [(.taskArn|split("/")[-1]|.[0:12]),.lastStatus,(.healthStatus//"UNKNOWN")] | @tsv' <<<"$tasks_json")
  while IFS=$'\t' read -r c_name c_status c_health; do
    [[ -n "$c_name" ]] || continue
    configured=0
    if [[ -n "$taskdef_json" ]] && jq -e --arg c "$c_name" '.taskDefinition.containerDefinitions[]? | select(.name==$c and .healthCheck != null)' <<<"$taskdef_json" >/dev/null 2>&1; then configured=1; fi
    if [[ "$c_status" != RUNNING ]]; then
      bad "Container $name/$c_name" "status=$c_status"
    elif [[ "$c_health" == UNHEALTHY ]]; then
      bad "Container $name/$c_name" 'UNHEALTHY'
    elif [[ "$c_health" == HEALTHY ]]; then
      ok "Container $name/$c_name" 'RUNNING / HEALTHY'
    elif [[ "$configured" -eq 1 ]]; then
      warn "Container $name/$c_name" "RUNNING / health=$c_health (check configurado)"
    else
      ok "Container $name/$c_name" 'RUNNING / sem healthcheck individual'
    fi
  done < <(jq -r '.tasks[]?.containers[]? | [.name,.lastStatus,(.healthStatus//"UNKNOWN")] | @tsv' <<<"$tasks_json")
  if [[ "$name" == monitoring ]]; then
    monitor_task="$(jq -r '.tasks[0].taskArn // empty' <<<"$tasks_json")"
  fi
done

section 'LOAD BALANCER E TARGET GROUPS'
alb_json="$(aws_json elbv2 describe-load-balancers --names "$ALB_NAME")" || alb_json=''
ALB_DNS=''; VPC_ID=''; ALB_ARN=''
if [[ -z "$alb_json" ]]; then
  bad 'ALB' 'Falha ao consultar ou ALB ausente'
else
  ALB_DNS="$(jq -r '.LoadBalancers[0].DNSName // empty' <<<"$alb_json")"
  VPC_ID="$(jq -r '.LoadBalancers[0].VpcId // empty' <<<"$alb_json")"
  ALB_ARN="$(jq -r '.LoadBalancers[0].LoadBalancerArn // empty' <<<"$alb_json")"
  alb_state="$(jq -r '.LoadBalancers[0].State.Code // "?"' <<<"$alb_json")"
  if [[ "$alb_state" == active && -n "$ALB_DNS" ]]; then ok 'ALB' "active | $ALB_DNS"; else bad 'ALB' "state=$alb_state"; fi
fi
if [[ -n "$ALB_ARN" ]]; then
  listeners="$(aws_json elbv2 describe-listeners --load-balancer-arn "$ALB_ARN")" || listeners=''
  if [[ -n "$listeners" ]] && jq -e '.Listeners[]? | select(.Protocol=="HTTP" and .Port==80)' <<<"$listeners" >/dev/null 2>&1; then
    ok 'ALB listener HTTP' 'Porta 80 configurada'
  else bad 'ALB listener HTTP' 'Porta 80 ausente / erro de consulta'; fi
fi
for item in 'frontend:2' 'backend:2' 'grafana:1'; do
  name="${item%%:*}"; expected="${item##*:}"
  tg_json="$(aws_json elbv2 describe-target-groups --names "${BASE_NAME}-${name}-tg")" || tg_json=''
  arn=''
  if [[ -n "$tg_json" ]]; then arn="$(jq -r '.TargetGroups[0].TargetGroupArn // empty' <<<"$tg_json")"; fi
  if [[ -z "$arn" ]]; then bad "Target Group $name" 'Ausente / consulta falhou'; continue; fi
  health="$(aws_json elbv2 describe-target-health --target-group-arn "$arn")" || health=''
  if [[ -z "$health" ]]; then bad "Target Group $name" 'Falha no describe-target-health'; continue; fi
  healthy="$(jq '[.TargetHealthDescriptions[]? | select(.TargetHealth.State=="healthy")] | length' <<<"$health")"
  unhealthy="$(jq '[.TargetHealthDescriptions[]? | select(.TargetHealth.State=="unhealthy")] | length' <<<"$health")"
  draining="$(jq '[.TargetHealthDescriptions[]? | select(.TargetHealth.State=="draining")] | length' <<<"$health")"
  total="$(jq '.TargetHealthDescriptions | length' <<<"$health")"
  if (( healthy >= expected && unhealthy == 0 )); then
    ok "Target Group $name" "$healthy/$expected healthy; draining=$draining"
  elif (( healthy == 0 || unhealthy > 0 )); then
    reasons="$(jq -r '[.TargetHealthDescriptions[]? | select(.TargetHealth.State!="healthy") | .TargetHealth.Reason // .TargetHealth.State] | unique | join(",")' <<<"$health")"
    bad "Target Group $name" "healthy=$healthy/$expected; unhealthy=$unhealthy; targets=$total; $reasons"
  else
    warn "Target Group $name" "healthy=$healthy/$expected; draining=$draining"
  fi
done

section 'TESTES HTTP PUBLICOS'
http_check() {
  local label="$1" path="$2" valid="$3" code body
  [[ -n "$ALB_DNS" ]] || { bad "$label" 'ALB sem DNS'; return; }
  # Only curl a trusted DNS returned from the exact named ALB.
  if [[ ! "$ALB_DNS" =~ ^[A-Za-z0-9.-]+\.elb\.amazonaws\.com$ ]]; then bad "$label" 'DNS de ALB inesperado'; return; fi
  code="$(curl -sS --connect-timeout 4 --max-time 12 -o /dev/null -w '%{http_code}' "http://${ALB_DNS}${path}" 2>/dev/null)" || code='000'
  case ",$valid," in *",$code,"*) ok "$label" "HTTP $code $path";; *) bad "$label" "HTTP $code $path (esperado $valid)";; esac
}
http_check 'Frontend /' '/' '200'
http_check 'Frontend /health' '/health' '200'
http_check 'Backend /api/health' '/api/health' '200'
http_check 'Backend /api/health/db' '/api/health/db' '200'
http_check 'Grafana /grafana/' '/grafana/' '200,301,302'
http_check 'Grafana /grafana/api/health' '/grafana/api/health' '200'

section 'BANCOS RDS'
for item in "${BASE_NAME}-db:aplicacao" "${BASE_NAME}-monitoring-db:monitoramento"; do
  identifier="${item%%:*}"; label="${item##*:}"
  rds_json="$(aws_json rds describe-db-instances --db-instance-identifier "$identifier")" || rds_json=''
  if [[ -z "$rds_json" ]]; then bad "RDS $label" 'Nao encontrado / erro de permissao'; continue; fi
  db_state="$(jq -r '.DBInstances[0].DBInstanceStatus // "?"' <<<"$rds_json")"
  db_endpoint="$(jq -r '.DBInstances[0].Endpoint.Address // "?"' <<<"$rds_json")"
  if [[ "$db_state" == available ]]; then ok "RDS $label" "available | $db_endpoint"; else bad "RDS $label" "status=$db_state"; fi
  if [[ "$label" == monitoramento ]]; then
    monitoring_db_secret="$(jq -r '.DBInstances[0].MasterUserSecret.SecretArn // empty' <<<"$rds_json")"
  fi
done

section 'SECRETS MANAGER (METADADOS, SEM SENHAS)'
for item in "${BASE_NAME}/monitoring/grafana-admin:Grafana" "${monitoring_db_secret:-}:RDS-monitoramento"; do
  secret_id="${item%:*}"; label="${item##*:}"
  if [[ -z "$secret_id" ]]; then warn "Secret $label" 'ARN nao disponivel'; continue; fi
  meta="$(aws_json secretsmanager describe-secret --secret-id "$secret_id")" || meta=''
  if [[ -z "$meta" ]]; then warn "Secret $label" 'Nao encontrado / sem permissao'; continue; fi
  if jq -e '(.DeletedDate == null) and ([.VersionIdsToStages[]?[]?] | index("AWSCURRENT") != null)' <<<"$meta" >/dev/null 2>&1; then
    ok "Secret $label" 'AWSCURRENT presente; sem exclusao agendada'
  else
    bad "Secret $label" 'Sem AWSCURRENT ou exclusao agendada'
  fi
done

section 'REDE E LOGS'
if [[ -n "$VPC_ID" ]]; then
  vpc_json="$(aws_json ec2 describe-vpcs --vpc-ids "$VPC_ID")" || vpc_json=''
  if [[ -n "$vpc_json" ]] && jq -e '.Vpcs[0].State=="available"' <<<"$vpc_json" >/dev/null 2>&1; then
    ok 'VPC' "$VPC_ID available"
  else bad 'VPC' "$VPC_ID nao available"; fi
  nat_json="$(aws_json ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}")" || nat_json=''
  if [[ -n "$nat_json" ]]; then
    nat_available="$(jq '[.NatGateways[]? | select(.State=="available")] | length' <<<"$nat_json")"
    nat_pending="$(jq '[.NatGateways[]? | select(.State=="pending")] | length' <<<"$nat_json")"
    if (( nat_available >= 2 )); then ok 'NAT Gateways' "$nat_available available";
    elif (( nat_available == 1 )); then warn 'NAT Gateways' '1 disponivel; verificar resiliencia por AZ';
    else bad 'NAT Gateways' "0 available; pending=$nat_pending"; fi
  else warn 'NAT Gateways' 'Falha na consulta (permissao?)'; fi
else
  warn 'VPC e NAT Gateways' 'ALB nao retornou VPC ID'
fi
for group in "/ecs/${BASE_NAME}/frontend" "/ecs/${BASE_NAME}/backend" "$LOG_GROUP"; do
  lg="$(aws_json logs describe-log-groups --log-group-name-prefix "$group")" || lg=''
  if [[ -n "$lg" ]] && jq -e --arg g "$group" '.logGroups[]? | select(.logGroupName==$g)' <<<"$lg" >/dev/null 2>&1; then
    ok 'CloudWatch Logs' "$group"
  else warn 'CloudWatch Logs' "Nao foi possivel confirmar $group"; fi
done

section 'BOOTSTRAP DO MONITORAMENTO (TAREFA ATUAL)'
if [[ -n "${monitor_task:-}" ]]; then
  task_id="${monitor_task##*/}"
  stream="monitoring-bootstrap/monitoring-bootstrap/${task_id}"
  bootstrap_logs="$(aws_json logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$stream" --start-from-head --limit 1000)" || bootstrap_logs=''
  if [[ -z "$bootstrap_logs" ]]; then
    warn 'Bootstrap NOVA' 'Log stream da tarefa atual indisponivel'
  elif jq -e '.events[]?.message | contains("NOVA monitoring bootstrap complete")' <<<"$bootstrap_logs" >/dev/null 2>&1; then
    ok 'Bootstrap NOVA' "Concluido na tarefa atual ${task_id:0:12}"
  elif jq -e '.events[]?.message | contains("MONITORING BOOTSTRAP FAILED")' <<<"$bootstrap_logs" >/dev/null 2>&1; then
    bad 'Bootstrap NOVA' 'Falha na tarefa atual; revisar CloudWatch Logs'
    jq -r '.events[]?.message | select(contains("MONITORING BOOTSTRAP FAILED"))' <<<"$bootstrap_logs" | tail -n 2
  else
    warn 'Bootstrap NOVA' 'Sem conclusao registrada na tarefa atual'
  fi
else
  bad 'Bootstrap NOVA' 'Nao existe tarefa atual de monitoramento RUNNING'
fi

section 'ECR (IMAGENS DISPONIVEIS)'
for name in frontend backend; do
  repository="${BASE_NAME}-${name}"
  ecr_json="$(aws_json ecr describe-repositories --repository-names "$repository")" || ecr_json=''
  if [[ -z "$ecr_json" ]] || ! jq -e '.repositories | length>0' <<<"$ecr_json" >/dev/null 2>&1; then
    warn "ECR $name" 'Repositorio ausente ou sem permissao'
    continue
  fi
  images_json="$(aws_json ecr describe-images --repository-name "$repository" --max-results 50)" || images_json=''
  if [[ -z "$images_json" ]]; then warn "ECR $name" 'Repositorio existe; imagens nao consultaveis';
  elif jq -e '.imageDetails | length>0' <<<"$images_json" >/dev/null 2>&1; then ok "ECR $name" 'Repositorio com imagens';
  else warn "ECR $name" 'Repositorio sem imagens'; fi
done

section 'RESUMO'
printf 'PASS: %d | WARN: %d | FAIL: %d\n' "$PASS" "$WARN" "$FAIL"
if (( FAIL > 0 )); then
  printf 'RESULTADO: FALHAS DETECTADAS (exit 1)\n'
  exit 1
fi
if (( WARN > 0 )); then
  printf 'RESULTADO: SERVICOS PRINCIPAIS SEM FALHAS, MAS HA AVISOS (exit 0)\n'
  exit 0
fi
printf 'RESULTADO: TODOS OS TESTES EXECUTADOS PASSARAM (exit 0)\n'
printf 'Nota: este auditor nao prova login interativo, fluxo de negocio completo ou atualizacao de cada metrica.\n'
exit 0