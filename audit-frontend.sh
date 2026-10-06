#!/usr/bin/env bash

# =============================================================================
# NOVA - FRONTEND FORENSIC AUDIT
# =============================================================================
#
# OBJETIVO
#   Descobrir exatamente por que:
#
#       cloudstart-dev-frontend
#       Desired=2
#       Running=0
#       ExitCode=1
#
#   A auditoria cruza:
#     1. código local
#     2. Dockerfile / nginx.conf
#     3. imagem Docker local
#     4. ECR
#     5. ECS Task Definition
#     6. ECS Service
#     7. tasks STOPPED
#     8. CloudWatch Logs
#     9. ALB
#    10. Target Group
#    11. health checks
#    12. Security Groups
#    13. DNS / HTTP
#
# SEGURANÇA
#   - Não executa terraform apply
#   - Não modifica Terraform
#   - Não cria recursos AWS
#   - Não atualiza ECS
#   - Não reinicia tasks
#   - Não expõe valores de secrets
#   - Não cria artefatos dentro do repositório
#
# SAÍDA
#   /tmp/nova-frontend-audit-YYYYMMDD-HHMMSS/
#
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# CONFIGURAÇÃO
# -----------------------------------------------------------------------------

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
AUDIT_DIR="/tmp/nova-frontend-audit-${TIMESTAMP}"

mkdir -p "$AUDIT_DIR"

REPORT="$AUDIT_DIR/report.log"
FAILURES="$AUDIT_DIR/failures.log"
WARNINGS="$AUDIT_DIR/warnings.log"

PASS=0
WARN=0
FAIL=0
INFO=0

AWS_REGION="${AWS_REGION:-us-east-1}"

EXPECTED_SERVICE="cloudstart-dev-frontend"
EXPECTED_REPOSITORY="cloudstart-dev-frontend"
EXPECTED_IMAGE_TAG="v0.1.0"

# -----------------------------------------------------------------------------
# CORES
# -----------------------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    MAGENTA=''
    RESET=''
fi

# -----------------------------------------------------------------------------
# FUNÇÕES
# -----------------------------------------------------------------------------

log() {
    echo "$*" | tee -a "$REPORT"
}

section() {
    echo
    echo "==============================================================================" | tee -a "$REPORT"
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$REPORT"
    echo "==============================================================================" | tee -a "$REPORT"
}

pass() {
    PASS=$((PASS + 1))
    echo -e "${GREEN}[PASS]${RESET} $1" | tee -a "$REPORT"
}

warn() {
    WARN=$((WARN + 1))
    echo -e "${YELLOW}[WARN]${RESET} $1" | tee -a "$REPORT" "$WARNINGS"
}

fail() {
    FAIL=$((FAIL + 1))
    echo -e "${RED}[FAIL]${RESET} $1" | tee -a "$REPORT" "$FAILURES"
}

info() {
    INFO=$((INFO + 1))
    echo -e "${BLUE}[INFO]${RESET} $1" | tee -a "$REPORT"
}

run_cmd() {
    local description="$1"
    shift

    echo
    echo ">>> $description" | tee -a "$REPORT"

    "$@" 2>&1 | tee -a "$REPORT"

    return "${PIPESTATUS[0]}"
}

require_command() {
    local command_name="$1"

    if command -v "$command_name" >/dev/null 2>&1; then
        pass "Comando disponível: $command_name"
        return 0
    else
        fail "Comando ausente: $command_name"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# INICIALIZAÇÃO
# -----------------------------------------------------------------------------

{
    echo "NOVA - FRONTEND FORENSIC AUDIT"
    echo "Timestamp: $(date -Is)"
    echo "Audit directory: $AUDIT_DIR"
    echo "Working directory: $(pwd)"
    echo "AWS_REGION: $AWS_REGION"
    echo
} > "$REPORT"

: > "$FAILURES"
: > "$WARNINGS"

# -----------------------------------------------------------------------------
# 1. AMBIENTE
# -----------------------------------------------------------------------------

section "1. AMBIENTE"

log "Host:"
hostname | tee -a "$REPORT"

log
log "Usuário:"
whoami | tee -a "$REPORT"

log
log "Diretório:"
pwd | tee -a "$REPORT"

log
log "Sistema:"
uname -a | tee -a "$REPORT"

log
log "Ferramentas:"

require_command aws
require_command terraform
require_command docker
require_command curl
require_command grep
require_command sed
require_command python3

# -----------------------------------------------------------------------------
# 2. VERSÕES
# -----------------------------------------------------------------------------

section "2. VERSÕES"

terraform version 2>&1 | tee -a "$REPORT"
aws --version 2>&1 | tee -a "$REPORT"
docker --version 2>&1 | tee -a "$REPORT"
curl --version 2>&1 | head -n 1 | tee -a "$REPORT"
python3 --version 2>&1 | tee -a "$REPORT"

# -----------------------------------------------------------------------------
# 3. AWS IDENTIDADE
# -----------------------------------------------------------------------------

section "3. AWS IDENTITY"

AWS_IDENTITY_FILE="$AUDIT_DIR/aws-identity.json"

if aws sts get-caller-identity \
    --region "$AWS_REGION" \
    > "$AWS_IDENTITY_FILE" 2>&1; then

    pass "AWS CLI autenticado."

    cat "$AWS_IDENTITY_FILE" | tee -a "$REPORT"

    ACCOUNT_ID="$(
        aws sts get-caller-identity \
            --query 'Account' \
            --output text \
            2>/dev/null || true
    )"

    CALLER_ARN="$(
        aws sts get-caller-identity \
            --query 'Arn' \
            --output text \
            2>/dev/null || true
    )"

    log "Account ID: $ACCOUNT_ID"
    log "Caller ARN: $CALLER_ARN"

else
    fail "AWS CLI não conseguiu executar sts get-caller-identity."
    cat "$AWS_IDENTITY_FILE" | tee -a "$REPORT"
fi

# -----------------------------------------------------------------------------
# 4. TERRAFORM OUTPUTS
# -----------------------------------------------------------------------------

section "4. TERRAFORM OUTPUTS"

if [[ -d ".terraform" ]]; then
    pass ".terraform existe."
else
    warn ".terraform não existe."
fi

CLUSTER="$(
    terraform output -raw ecs_cluster_name 2>/dev/null || true
)"

ALB_DNS="$(
    terraform output -raw alb_dns_name 2>/dev/null || true
)"

if [[ -z "$CLUSTER" ]]; then
    fail "Não foi possível obter ecs_cluster_name pelo Terraform."
else
    pass "Cluster Terraform: $CLUSTER"
fi

if [[ -z "$ALB_DNS" ]]; then
    fail "Não foi possível obter alb_dns_name pelo Terraform."
else
    pass "ALB DNS: $ALB_DNS"
fi

# -----------------------------------------------------------------------------
# 5. CÓDIGO LOCAL - FRONTEND
# -----------------------------------------------------------------------------

section "5. CÓDIGO LOCAL - FRONTEND"

if [[ -f "apps/frontend/Dockerfile" ]]; then
    pass "apps/frontend/Dockerfile encontrado."

    {
        echo
        echo "----- apps/frontend/Dockerfile -----"
        nl -ba apps/frontend/Dockerfile
    } | tee -a "$REPORT"
else
    fail "apps/frontend/Dockerfile não encontrado."
fi

if [[ -f "apps/frontend/nginx.conf" ]]; then
    pass "apps/frontend/nginx.conf encontrado."

    {
        echo
        echo "----- apps/frontend/nginx.conf -----"
        nl -ba apps/frontend/nginx.conf
    } | tee -a "$REPORT"
else
    fail "apps/frontend/nginx.conf não encontrado."
fi

if [[ -d "apps/frontend/public" ]]; then

    FILE_COUNT="$(
        find apps/frontend/public \
            -type f \
            | wc -l
    )"

    if [[ "$FILE_COUNT" -gt 0 ]]; then
        pass "Frontend public contém $FILE_COUNT arquivo(s)."
    else
        fail "apps/frontend/public está vazio."
    fi

else
    fail "apps/frontend/public não existe."
fi

# -----------------------------------------------------------------------------
# 6. ANÁLISE ESTÁTICA DO NGINX
# -----------------------------------------------------------------------------

section "6. ANÁLISE ESTÁTICA DO NGINX"

NGINX_CONF="apps/frontend/nginx.conf"

if [[ -f "$NGINX_CONF" ]]; then

    echo
    echo "### Referências a 'backend' ###"

    if grep -nEi 'backend|proxy_pass|upstream' "$NGINX_CONF" \
        | tee -a "$REPORT"; then

        warn "nginx.conf contém referências a backend/upstream."
    else
        pass "Nenhuma referência a backend/upstream encontrada."
    fi

    echo
    echo "### Portas ###"

    grep -nEi 'listen|proxy_pass' "$NGINX_CONF" \
        | tee -a "$REPORT" || true

    echo
    echo "### Health endpoints ###"

    grep -nEi 'health|location' "$NGINX_CONF" \
        | tee -a "$REPORT" || true

    echo
    echo "### Variáveis/hosts hardcoded ###"

    grep -nEi \
        'localhost|127\.0\.0\.1|backend:|http://|https://' \
        "$NGINX_CONF" \
        | tee -a "$REPORT" || true

    if grep -qE 'proxy_pass[[:space:]]+http://backend:8000' "$NGINX_CONF"; then
        fail "nginx.conf contém proxy_pass para backend:8000. Isso precisa ser validado contra a arquitetura ECS."
    fi

else
    fail "Não foi possível analisar nginx.conf."
fi

# -----------------------------------------------------------------------------
# 7. GIT - ESTADO LOCAL
# -----------------------------------------------------------------------------

section "7. GIT"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then

    pass "Diretório é Git repository."

    BRANCH="$(git branch --show-current 2>/dev/null || true)"

    log "Branch atual: ${BRANCH:-<detached HEAD>}"

    if [[ "$BRANCH" == "main" ]]; then
        warn "Você está na branch main."
    else
        pass "Branch atual: ${BRANCH:-detached}"
    fi

    log
    log "Git status:"
    git status --short | tee -a "$REPORT"

    log
    log "Último commit:"
    git log -1 --oneline | tee -a "$REPORT"

else
    warn "Diretório atual não é um Git repository."
fi

# -----------------------------------------------------------------------------
# 8. DOCKER - STATUS DO DAEMON
# -----------------------------------------------------------------------------

section "8. DOCKER DAEMON"

if docker info > "$AUDIT_DIR/docker-info.txt" 2>&1; then
    pass "Docker daemon acessível."
else
    fail "Docker daemon não está acessível."

    cat "$AUDIT_DIR/docker-info.txt" | tee -a "$REPORT"
fi

# -----------------------------------------------------------------------------
# 9. IMAGEM LOCAL DO FRONTEND
# -----------------------------------------------------------------------------

section "9. IMAGEM DO FRONTEND - LOCAL"

LOCAL_IMAGE="cloudstart/frontend:v0.1.0"

if docker image inspect "$LOCAL_IMAGE" \
    > "$AUDIT_DIR/local-image-inspect.json" 2>&1; then

    pass "Imagem local encontrada: $LOCAL_IMAGE"

    docker image inspect "$LOCAL_IMAGE" \
        --format '
Image={{.RepoTags}}
ID={{.Id}}
Created={{.Created}}
Size={{.Size}}
Entrypoint={{json .Config.Entrypoint}}
Cmd={{json .Config.Cmd}}
WorkingDir={{.Config.WorkingDir}}
User={{json .Config.User}}
ExposedPorts={{json .Config.ExposedPorts}}
' \
        | tee -a "$REPORT"

else
    warn "Imagem local $LOCAL_IMAGE não encontrada."
    info "Os testes nginx -t locais serão pulados."
fi

# -----------------------------------------------------------------------------
# 10. NGINX - TESTE REAL DENTRO DA IMAGEM
# -----------------------------------------------------------------------------

section "10. NGINX - TESTE DENTRO DA IMAGEM"

if docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then

    echo
    echo "### nginx -t com network=none ###"

    NGINX_TEST_FILE="$AUDIT_DIR/nginx-test.txt"

    if docker run \
        --rm \
        --network none \
        --entrypoint nginx \
        "$LOCAL_IMAGE" \
        -t \
        > "$NGINX_TEST_FILE" 2>&1; then

        pass "nginx -t foi aprovado dentro da imagem."

        cat "$NGINX_TEST_FILE" | tee -a "$REPORT"

    else

        fail "nginx -t FALHOU dentro da imagem."

        cat "$NGINX_TEST_FILE" | tee -a "$REPORT"

        if grep -Eqi \
            'host not found|backend|upstream|emerg|failed' \
            "$NGINX_TEST_FILE"; then

            fail "Falha do nginx -t contém indícios fortes de problema de resolução/configuração."
        fi
    fi

else
    info "Pulando nginx -t porque a imagem local não existe."
fi

# -----------------------------------------------------------------------------
# 11. NGINX - CONFIGURAÇÃO EFETIVA DA IMAGEM
# -----------------------------------------------------------------------------

section "11. NGINX - CONFIGURAÇÃO EFETIVA"

if docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then

    docker run \
        --rm \
        --network none \
        --entrypoint nginx \
        "$LOCAL_IMAGE" \
        -T \
        > "$AUDIT_DIR/nginx-effective-config.txt" 2>&1 || true

    sed -n '1,260p' \
        "$AUDIT_DIR/nginx-effective-config.txt" \
        | tee -a "$REPORT"

    if grep -Eqi \
        'host not found|backend:8000|proxy_pass' \
        "$AUDIT_DIR/nginx-effective-config.txt"; then

        warn "Configuração efetiva do Nginx contém referência a backend/upstream."
    fi

else
    info "Pulando análise da configuração efetiva."
fi

# -----------------------------------------------------------------------------
# 12. AWS ECS SERVICE
# -----------------------------------------------------------------------------

section "12. ECS SERVICE"

if [[ -z "$CLUSTER" ]]; then
    fail "Não foi possível consultar ECS sem cluster."
else

    SERVICE_FILE="$AUDIT_DIR/ecs-service.json"

    if aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$EXPECTED_SERVICE" \
        --region "$AWS_REGION" \
        --output json \
        > "$SERVICE_FILE" 2>&1; then

        pass "ECS service encontrado."

        aws ecs describe-services \
            --cluster "$CLUSTER" \
            --services "$EXPECTED_SERVICE" \
            --region "$AWS_REGION" \
            --query 'services[0].{
                Service:serviceName,
                Status:status,
                Desired:desiredCount,
                Running:runningCount,
                Pending:pendingCount,
                TaskDefinition:taskDefinition,
                HealthGrace:healthCheckGracePeriodSeconds,
                DeploymentConfiguration:deploymentConfiguration,
                DeploymentCircuitBreaker:deploymentConfiguration.deploymentCircuitBreaker,
                Deployments:deployments[].{
                    Id:id,
                    Status:status,
                    Desired:desiredCount,
                    Running:runningCount,
                    Pending:pendingCount,
                    Failed:failedTasks,
                    Rollout:rolloutState,
                    Reason:rolloutStateReason
                },
                LoadBalancers:loadBalancers[],
                Events:events[0:20].message
            }' \
            --output json \
            | tee -a "$REPORT"

    else
        fail "Falha ao consultar ECS frontend."
        cat "$SERVICE_FILE" | tee -a "$REPORT"
    fi
fi

# -----------------------------------------------------------------------------
# 13. ECS DEPLOYMENT / ESTADO
# -----------------------------------------------------------------------------

section "13. ECS DEPLOYMENT STATE"

if [[ -n "$CLUSTER" ]]; then

    FRONT_DESIRED="$(
        aws ecs describe-services \
            --cluster "$CLUSTER" \
            --services "$EXPECTED_SERVICE" \
            --region "$AWS_REGION" \
            --query 'services[0].desiredCount' \
            --output text \
            2>/dev/null || echo "0"
    )"

    FRONT_RUNNING="$(
        aws ecs describe-services \
            --cluster "$CLUSTER" \
            --services "$EXPECTED_SERVICE" \
            --region "$AWS_REGION" \
            --query 'services[0].runningCount' \
            --output text \
            2>/dev/null || echo "0"
    )"

    FRONT_PENDING="$(
        aws ecs describe-services \
            --cluster "$CLUSTER" \
            --services "$EXPECTED_SERVICE" \
            --region "$AWS_REGION" \
            --query 'services[0].pendingCount' \
            --output text \
            2>/dev/null || echo "0"
    )"

    log "Desired : $FRONT_DESIRED"
    log "Running : $FRONT_RUNNING"
    log "Pending : $FRONT_PENDING"

    if [[ "$FRONT_RUNNING" == "$FRONT_DESIRED" && "$FRONT_DESIRED" != "0" ]]; then
        pass "Frontend está com Desired=Running."
    else
        fail "Frontend está inconsistente: Desired=$FRONT_DESIRED Running=$FRONT_RUNNING Pending=$FRONT_PENDING."
    fi

    SERVICE_EVENTS="$AUDIT_DIR/service-events.txt"

    aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$EXPECTED_SERVICE" \
        --region "$AWS_REGION" \
        --query 'services[0].events[0:30].message' \
        --output text \
        > "$SERVICE_EVENTS" 2>&1 || true

    cat "$SERVICE_EVENTS" | tee -a "$REPORT"

    if grep -Eqi \
        'CannotPullContainerError|EssentialContainerExited|health|failed|unable|draining|deregistered' \
        "$SERVICE_EVENTS"; then

        warn "Eventos do ECS contêm sinais de falha/substituição."
        grep -Ein \
            'CannotPullContainerError|EssentialContainerExited|health|failed|unable|draining|deregistered' \
            "$SERVICE_EVENTS" \
            | tee -a "$REPORT"
    fi
fi

# -----------------------------------------------------------------------------
# 14. TASK DEFINITION
# -----------------------------------------------------------------------------

section "14. TASK DEFINITION"

TASK_DEFINITION="$(
    aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$EXPECTED_SERVICE" \
        --region "$AWS_REGION" \
        --query 'services[0].taskDefinition' \
        --output text \
        2>/dev/null || true
)"

if [[ -z "$TASK_DEFINITION" || "$TASK_DEFINITION" == "None" ]]; then

    fail "Não foi possível identificar a task definition."

else

    pass "Task Definition: $TASK_DEFINITION"

    TASKDEF_FILE="$AUDIT_DIR/task-definition.json"

    if aws ecs describe-task-definition \
        --task-definition "$TASK_DEFINITION" \
        --region "$AWS_REGION" \
        --output json \
        > "$TASKDEF_FILE" 2>&1; then

        pass "Task definition consultada."

        aws ecs describe-task-definition \
            --task-definition "$TASK_DEFINITION" \
            --region "$AWS_REGION" \
            --query 'taskDefinition.{
                Family:family,
                Revision:revision,
                CPU:cpu,
                Memory:memory,
                NetworkMode:networkMode,
                RequiresCompatibilities:requiresCompatibilities,
                ExecutionRole:executionRoleArn,
                TaskRole:taskRoleArn,
                Containers:containerDefinitions[?name==`frontend`].{
                    Name:name,
                    Image:image,
                    Essential:essential,
                    CPU:cpu,
                    Memory:memory,
                    MemoryReservation:memoryReservation,
                    EntryPoint:entryPoint,
                    Command:command,
                    WorkingDirectory:workingDirectory,
                    PortMappings:portMappings,
                    HealthCheck:healthCheck,
                    LogConfiguration:logConfiguration
                }
            }' \
            --output json \
            | tee -a "$REPORT"

    else
        fail "Falha ao consultar task definition."
        cat "$TASKDEF_FILE" | tee -a "$REPORT"
    fi
fi

# -----------------------------------------------------------------------------
# 15. IMAGEM REAL USADA PELA AWS
# -----------------------------------------------------------------------------

section "15. IMAGEM REAL DA TASK DEFINITION"

if [[ -n "$TASK_DEFINITION" && "$TASK_DEFINITION" != "None" ]]; then

    AWS_FRONTEND_IMAGE="$(
        aws ecs describe-task-definition \
            --task-definition "$TASK_DEFINITION" \
            --region "$AWS_REGION" \
            --query 'taskDefinition.containerDefinitions[?name==`frontend`].image | [0]' \
            --output text \
            2>/dev/null || true
    )"

    log "AWS frontend image:"
    log "$AWS_FRONTEND_IMAGE"

    EXPECTED_ECR_PATTERN=".*/${EXPECTED_REPOSITORY}:${EXPECTED_IMAGE_TAG}$"

    if [[ "$AWS_FRONTEND_IMAGE" =~ $EXPECTED_ECR_PATTERN ]]; then
        pass "Task definition usa o repositório/tag esperados."
    else
        fail "Task definition usa imagem inesperada: $AWS_FRONTEND_IMAGE"
    fi

    if [[ "$AWS_FRONTEND_IMAGE" == *":latest" ]]; then
        warn "Task definition usa uma tag latest; reprodutibilidade deveria ser melhorada."
    fi

fi

# -----------------------------------------------------------------------------
# 16. ECR
# -----------------------------------------------------------------------------

section "16. ECR"

ECR_IMAGE_FILE="$AUDIT_DIR/ecr-image.json"

if aws ecr describe-repositories \
    --repository-names "$EXPECTED_REPOSITORY" \
    --region "$AWS_REGION" \
    > "$AUDIT_DIR/ecr-repository.json" 2>&1; then

    pass "ECR repository existe."

else
    fail "ECR repository não existe ou não está acessível."
fi

if aws ecr describe-images \
    --repository-name "$EXPECTED_REPOSITORY" \
    --region "$AWS_REGION" \
    --image-ids imageTag="$EXPECTED_IMAGE_TAG" \
    --output json \
    > "$ECR_IMAGE_FILE" 2>&1; then

    pass "Imagem ECR $EXPECTED_IMAGE_TAG existe."

    aws ecr describe-images \
        --repository-name "$EXPECTED_REPOSITORY" \
        --region "$AWS_REGION" \
        --image-ids imageTag="$EXPECTED_IMAGE_TAG" \
        --query 'imageDetails[0].{
            Digest:imageDigest,
            Tags:imageTags,
            Pushed:imagePushedAt,
            Size:imageSizeInBytes,
            ScanStatus:imageScanStatus
        }' \
        --output json \
        | tee -a "$REPORT"

else
    fail "Imagem ECR $EXPECTED_IMAGE_TAG não existe."
    cat "$ECR_IMAGE_FILE" | tee -a "$REPORT"
fi

# -----------------------------------------------------------------------------
# 17. VALIDAR MANIFEST E DIGEST ECR
# -----------------------------------------------------------------------------

section "17. ECR MANIFEST"

if aws ecr batch-get-image \
    --repository-name "$EXPECTED_REPOSITORY" \
    --image-ids imageTag="$EXPECTED_IMAGE_TAG" \
    --region "$AWS_REGION" \
    --accepted-media-types \
        application/vnd.docker.distribution.manifest.v2+json \
        application/vnd.oci.image.manifest.v1+json \
        application/vnd.docker.distribution.manifest.list.v2+json \
    > "$AUDIT_DIR/ecr-manifest.json" 2>&1; then

    if grep -q '"images"' "$AUDIT_DIR/ecr-manifest.json"; then
        pass "ECR retorna manifest válido para $EXPECTED_IMAGE_TAG."
    else
        fail "ECR não retornou imagem para $EXPECTED_IMAGE_TAG."
    fi

else
    fail "batch-get-image falhou para ECR."
    cat "$AUDIT_DIR/ecr-manifest.json" | tee -a "$REPORT"
fi

# -----------------------------------------------------------------------------
# 18. TASKS STOPPED
# -----------------------------------------------------------------------------

section "18. TASKS STOPPED"

STOPPED_TASKS_FILE="$AUDIT_DIR/stopped-task-arns.txt"

if aws ecs list-tasks \
    --cluster "$CLUSTER" \
    --service-name "$EXPECTED_SERVICE" \
    --desired-status STOPPED \
    --region "$AWS_REGION" \
    --query 'taskArns[0:20]' \
    --output text \
    > "$STOPPED_TASKS_FILE" 2>&1; then

    STOPPED_TASKS="$(cat "$STOPPED_TASKS_FILE")"

    if [[ -z "$STOPPED_TASKS" ]]; then
        info "Nenhuma task STOPPED encontrada."
    else

        pass "Encontradas tasks STOPPED."

        STOPPED_DETAILS="$AUDIT_DIR/stopped-tasks.json"

        if aws ecs describe-tasks \
            --cluster "$CLUSTER" \
            --tasks $STOPPED_TASKS \
            --region "$AWS_REGION" \
            --output json \
            > "$STOPPED_DETAILS" 2>&1; then

            aws ecs describe-tasks \
                --cluster "$CLUSTER" \
                --tasks $STOPPED_TASKS \
                --region "$AWS_REGION" \
                --query 'tasks[].{
                    Task:taskArn,
                    CreatedAt:createdAt,
                    StartedAt:startedAt,
                    StoppedAt:stoppedAt,
                    LastStatus:lastStatus,
                    DesiredStatus:desiredStatus,
                    StopCode:stopCode,
                    StoppedReason:stoppedReason,
                    HealthStatus:healthStatus,
                    Containers:containers[].{
                        Name:name,
                        Image:image,
                        LastStatus:lastStatus,
                        HealthStatus:healthStatus,
                        ExitCode:exitCode,
                        Reason:reason,
                        RestartCount:restartCount
                    }
                }' \
                --output json \
                | tee -a "$REPORT"

            EXIT1_COUNT="$(
                python3 - "$STOPPED_DETAILS" <<'PY'
import json
import sys

path = sys.argv[1]

with open(path, encoding="utf-8") as f:
    data = json.load(f)

count = 0

for task in data.get("tasks", []):
    for container in task.get("containers", []):
        if container.get("name") == "frontend" and container.get("exitCode") == 1:
            count += 1

print(count)
PY
            )"

            log
            log "Frontend tasks com ExitCode=1: $EXIT1_COUNT"

            if [[ "$EXIT1_COUNT" -gt 0 ]]; then
                fail "Existem tasks frontend encerrando com ExitCode=1."
            fi

            if grep -Eqi \
                'EssentialContainerExited|CannotPullContainerError|CannotPull|failed|error|health' \
                "$STOPPED_DETAILS"; then

                warn "Evidências de erro aparecem nas tasks STOPPED."
            fi

        else
            fail "Não foi possível descrever tasks STOPPED."
            cat "$STOPPED_DETAILS" | tee -a "$REPORT"
        fi
    fi

else
    fail "Falha ao listar tasks STOPPED."
fi

# -----------------------------------------------------------------------------
# 19. FORENSIA TEMPORAL DAS TASKS
# -----------------------------------------------------------------------------

section "19. FORENSIA TEMPORAL"

if [[ -f "$STOPPED_DETAILS" ]]; then

    python3 - "$STOPPED_DETAILS" <<'PY' | tee -a "$REPORT"
import json
import sys
from datetime import datetime

path = sys.argv[1]

with open(path, encoding="utf-8") as f:
    data = json.load(f)

print("Task lifecycle:")
print()

for task in data.get("tasks", []):
    task_id = task.get("taskArn", "").split("/")[-1]
    created = task.get("createdAt")
    started = task.get("startedAt")
    stopped = task.get("stoppedAt")
    reason = task.get("stoppedReason")
    stop_code = task.get("stopCode")

    print(f"TASK={task_id}")
    print(f"  created = {created}")
    print(f"  started = {started}")
    print(f"  stopped = {stopped}")
    print(f"  stopCode = {stop_code}")
    print(f"  reason = {reason}")

    if started and stopped:
        try:
            s = datetime.fromisoformat(started.replace("Z", "+00:00"))
            e = datetime.fromisoformat(stopped.replace("Z", "+00:00"))
            print(f"  lifetime_seconds = {(e-s).total_seconds():.2f}")
        except Exception:
            pass

    for c in task.get("containers", []):
        if c.get("name") == "frontend":
            print(f"  container_exitCode = {c.get('exitCode')}")
            print(f"  container_reason = {c.get('reason')}")
            print(f"  container_health = {c.get('healthStatus')}")

    print()
PY

fi

# -----------------------------------------------------------------------------
# 20. CLOUDWATCH LOG CONFIGURATION
# -----------------------------------------------------------------------------

section "20. CLOUDWATCH LOG CONFIGURATION"

LOG_GROUP=""
LOG_PREFIX=""

if [[ -n "$TASK_DEFINITION" && "$TASK_DEFINITION" != "None" ]]; then

    LOG_CONFIG="$AUDIT_DIR/frontend-log-config.json"

    aws ecs describe-task-definition \
        --task-definition "$TASK_DEFINITION" \
        --region "$AWS_REGION" \
        --query 'taskDefinition.containerDefinitions[?name==`frontend`].logConfiguration' \
        --output json \
        > "$LOG_CONFIG" 2>&1 || true

    cat "$LOG_CONFIG" | tee -a "$REPORT"

    readarray -t LOG_VALUES < <(
        python3 - "$LOG_CONFIG" <<'PY'
import json
import sys

path = sys.argv[1]

with open(path, encoding="utf-8") as f:
    data = json.load(f)

cfg = data[0] if data else {}
options = cfg.get("options", {})

print(options.get("awslogs-group", ""))
print(options.get("awslogs-stream-prefix", ""))
print(options.get("awslogs-region", ""))
PY
    )

    LOG_GROUP="${LOG_VALUES[0]:-}"
    LOG_PREFIX="${LOG_VALUES[1]:-}"

    log "CloudWatch log group: ${LOG_GROUP:-<none>}"
    log "CloudWatch stream prefix: ${LOG_PREFIX:-<none>}"

    if [[ -z "$LOG_GROUP" ]]; then
        fail "Frontend não possui awslogs-group configurado."
    else
        pass "Frontend possui CloudWatch Logs configurado."
    fi

fi

# -----------------------------------------------------------------------------
# 21. CLOUDWATCH LOGS
# -----------------------------------------------------------------------------

section "21. CLOUDWATCH LOGS"

if [[ -n "$LOG_GROUP" ]]; then

    LOG_EVENTS="$AUDIT_DIR/frontend-cloudwatch.log"

    START_MS="$(
        python3 - <<'PY'
import time
print(int((time.time() - 3600) * 1000))
PY
    )"

    if aws logs filter-log-events \
        --log-group-name "$LOG_GROUP" \
        --start-time "$START_MS" \
        --region "$AWS_REGION" \
        --max-items 300 \
        > "$LOG_EVENTS" 2>&1; then

        if grep -q '"events"' "$LOG_EVENTS"; then

            pass "CloudWatch retornou eventos recentes."

            python3 - "$LOG_EVENTS" <<'PY' | tee -a "$REPORT"
import json
import sys
from datetime import datetime, timezone

path = sys.argv[1]

with open(path, encoding="utf-8") as f:
    data = json.load(f)

events = data.get("events", [])

for event in events[-100:]:
    ts = event.get("timestamp")
    message = event.get("message", "").rstrip()

    if ts:
        dt = datetime.fromtimestamp(ts / 1000, tz=timezone.utc)
        print(f"{dt.isoformat()} | {message}")
    else:
        print(message)
PY

            echo
            echo "### Erros Nginx relevantes ###"

            if grep -Eqi \
                'emerg|crit|error|failed|host not found|upstream|bind|permission denied|invalid' \
                "$LOG_EVENTS"; then

                fail "CloudWatch contém mensagens compatíveis com falha de inicialização Nginx/container."

                grep -Ein \
                    'emerg|crit|error|failed|host not found|upstream|bind|permission denied|invalid' \
                    "$LOG_EVENTS" \
                    | tee -a "$REPORT"
            else
                pass "Nenhuma mensagem óbvia de erro Nginx encontrada nos logs coletados."
            fi

        else
            warn "CloudWatch não retornou eventos no último período consultado."
        fi

    else
        warn "Não foi possível consultar CloudWatch Logs."
        cat "$LOG_EVENTS" | tee -a "$REPORT"
    fi

else
    warn "CloudWatch Logs não configurado; diagnóstico dos logs do processo ficará limitado."
fi

# -----------------------------------------------------------------------------
# 22. ALB - EXISTÊNCIA
# -----------------------------------------------------------------------------

section "22. ALB"

ALB_ARN="$(
    aws elbv2 describe-load-balancers \
        --names cloudstart-dev-alb \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text \
        2>/dev/null || true
)"

ALB_SG="$(
    aws elbv2 describe-load-balancers \
        --names cloudstart-dev-alb \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[0].SecurityGroups[0]' \
        --output text \
        2>/dev/null || true
)"

if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]]; then
    pass "ALB encontrado."
    log "ALB ARN: $ALB_ARN"
    log "ALB SG: $ALB_SG"
else
    fail "ALB não encontrado."
fi

# -----------------------------------------------------------------------------
# 23. ALB LISTENER / RULES
# -----------------------------------------------------------------------------

section "23. ALB LISTENER / ROUTING"

if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]]; then

    LISTENERS="$AUDIT_DIR/listeners.json"

    aws elbv2 describe-listeners \
        --load-balancer-arn "$ALB_ARN" \
        --region "$AWS_REGION" \
        --output json \
        > "$LISTENERS" 2>&1 || true

    cat "$LISTENERS" | tee -a "$REPORT"

    LISTENER_ARN="$(
        aws elbv2 describe-listeners \
            --load-balancer-arn "$ALB_ARN" \
            --region "$AWS_REGION" \
            --query 'Listeners[?Port==`80`].ListenerArn | [0]' \
            --output text \
            2>/dev/null || true
    )"

    if [[ -n "$LISTENER_ARN" && "$LISTENER_ARN" != "None" ]]; then

        pass "Listener HTTP :80 encontrado."

        RULES="$AUDIT_DIR/listener-rules.json"

        aws elbv2 describe-rules \
            --listener-arn "$LISTENER_ARN" \
            --region "$AWS_REGION" \
            --output json \
            > "$RULES" 2>&1 || true

        cat "$RULES" | tee -a "$REPORT"

        if grep -q 'cloudstart-dev-frontend-tg' "$RULES"; then
            pass "ALB possui regra/ação para frontend."
        else
            fail "ALB não mostra referência ao frontend target group."
        fi
    else
        fail "Listener HTTP :80 não encontrado."
    fi
fi

# -----------------------------------------------------------------------------
# 24. FRONTEND TARGET GROUP
# -----------------------------------------------------------------------------

section "24. FRONTEND TARGET GROUP"

FRONT_TG_ARN="$(
    aws elbv2 describe-target-groups \
        --names cloudstart-dev-frontend-tg \
        --region "$AWS_REGION" \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text \
        2>/dev/null || true
)"

if [[ -n "$FRONT_TG_ARN" && "$FRONT_TG_ARN" != "None" ]]; then

    pass "Frontend Target Group encontrado."

    aws elbv2 describe-target-groups \
        --target-group-arns "$FRONT_TG_ARN" \
        --region "$AWS_REGION" \
        --query 'TargetGroups[0].{
            Name:TargetGroupName,
            TargetType:TargetType,
            Protocol:Protocol,
            Port:Port,
            HealthCheckEnabled:HealthCheckEnabled,
            HealthCheckProtocol:HealthCheckProtocol,
            HealthCheckPort:HealthCheckPort,
            HealthCheckPath:HealthCheckPath,
            Matcher:Matcher.HttpCode,
            Interval:HealthCheckIntervalSeconds,
            Timeout:HealthCheckTimeoutSeconds,
            HealthyThreshold:HealthyThresholdCount,
            UnhealthyThreshold:UnhealthyThresholdCount
        }' \
        --output json \
        | tee -a "$REPORT"

else
    fail "Frontend Target Group não encontrado."
fi

# -----------------------------------------------------------------------------
# 25. TARGET HEALTH
# -----------------------------------------------------------------------------

section "25. TARGET HEALTH"

if [[ -n "$FRONT_TG_ARN" && "$FRONT_TG_ARN" != "None" ]]; then

    TARGET_HEALTH="$AUDIT_DIR/target-health.json"

    if aws elbv2 describe-target-health \
        --target-group-arn "$FRONT_TG_ARN" \
        --region "$AWS_REGION" \
        --output json \
        > "$TARGET_HEALTH" 2>&1; then

        cat "$TARGET_HEALTH" | tee -a "$REPORT"

        HEALTH_STATES="$(
            aws elbv2 describe-target-health \
                --target-group-arn "$FRONT_TG_ARN" \
                --region "$AWS_REGION" \
                --query 'TargetHealthDescriptions[].TargetHealth.State' \
                --output text \
                2>/dev/null || true
        )"

        log
        log "Target states: $HEALTH_STATES"

        if echo "$HEALTH_STATES" | grep -qw "healthy"; then
            pass "Existe target frontend healthy."
        else
            fail "Não existe target frontend healthy."
        fi

        echo
        echo "### Reasons ###"

        aws elbv2 describe-target-health \
            --target-group-arn "$FRONT_TG_ARN" \
            --region "$AWS_REGION" \
            --query 'TargetHealthDescriptions[].{
                Target:Target.Id,
                Port:Target.Port,
                State:TargetHealth.State,
                Reason:TargetHealth.Reason,
                Description:TargetHealth.Description
            }' \
            --output table \
            | tee -a "$REPORT"

    else
        fail "Falha ao consultar target health."
        cat "$TARGET_HEALTH" | tee -a "$REPORT"
    fi
fi

# -----------------------------------------------------------------------------
# 26. SECURITY GROUPS
# -----------------------------------------------------------------------------

section "26. SECURITY GROUPS"

FRONT_SG="$(
    aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$EXPECTED_SERVICE" \
        --region "$AWS_REGION" \
        --query 'services[0].networkConfiguration.awsvpcConfiguration.securityGroups[0]' \
        --output text \
        2>/dev/null || true
)"

log "Frontend SG: ${FRONT_SG:-<none>}"
log "ALB SG: ${ALB_SG:-<none>}"

if [[ -n "$FRONT_SG" && "$FRONT_SG" != "None" ]]; then

    aws ec2 describe-security-groups \
        --group-ids "$FRONT_SG" \
        --region "$AWS_REGION" \
        --output json \
        > "$AUDIT_DIR/frontend-security-group.json" 2>&1 || true

    cat "$AUDIT_DIR/frontend-security-group.json" | tee -a "$REPORT"

    FRONT_80_FROM_ALB="$(
        python3 - "$AUDIT_DIR/frontend-security-group.json" "$ALB_SG" <<'PY'
import json
import sys

path = sys.argv[1]
alb_sg = sys.argv[2]

with open(path, encoding="utf-8") as f:
    data = json.load(f)

found = False

for sg in data.get("SecurityGroups", []):
    for rule in sg.get("IpPermissions", []):
        if rule.get("FromPort") == 80 and rule.get("ToPort") == 80:
            for pair in rule.get("UserIdGroupPairs", []):
                if pair.get("GroupId") == alb_sg:
                    found = True

print("YES" if found else "NO")
PY
    )"

    if [[ "$FRONT_80_FROM_ALB" == "YES" ]]; then
        pass "Frontend SG permite TCP/80 a partir do ALB SG."
    else
        fail "Frontend SG não apresenta regra explícita TCP/80 vindo do ALB SG."
    fi

else
    fail "Não foi possível identificar Frontend SG."
fi

# -----------------------------------------------------------------------------
# 27. DNS DO ALB
# -----------------------------------------------------------------------------

section "27. ALB DNS"

if [[ -n "$ALB_DNS" ]]; then

    if getent hosts "$ALB_DNS" \
        > "$AUDIT_DIR/alb-dns.txt" 2>&1; then

        pass "ALB DNS resolve."

        cat "$AUDIT_DIR/alb-dns.txt" | tee -a "$REPORT"

    else
        fail "ALB DNS não resolve."

        cat "$AUDIT_DIR/alb-dns.txt" | tee -a "$REPORT"
    fi

else
    fail "ALB DNS não está disponível."
fi

# -----------------------------------------------------------------------------
# 28. HTTP DO FRONTEND
# -----------------------------------------------------------------------------

section "28. HTTP - FRONTEND"

if [[ -n "$ALB_DNS" ]]; then

    CURL_ROOT="$AUDIT_DIR/curl-root.txt"
    CURL_HEALTH="$AUDIT_DIR/curl-health.txt"

    if curl \
        --silent \
        --show-error \
        --max-time 20 \
        --connect-timeout 10 \
        --write-out '\nHTTP_STATUS=%{http_code}\nTIME=%{time_total}\n' \
        "http://${ALB_DNS}/" \
        > "$CURL_ROOT" 2>&1; then

        cat "$CURL_ROOT" | tee -a "$REPORT"

        ROOT_STATUS="$(
            grep 'HTTP_STATUS=' "$CURL_ROOT" \
                | tail -n 1 \
                | cut -d= -f2
        )"

        if [[ "$ROOT_STATUS" =~ ^2|^3 ]]; then
            pass "GET / respondeu HTTP $ROOT_STATUS."
        else
            fail "GET / respondeu HTTP $ROOT_STATUS."
        fi

    else
        fail "curl / falhou."
        cat "$CURL_ROOT" | tee -a "$REPORT"
    fi

    echo
    echo "### /health ###"

    if curl \
        --silent \
        --show-error \
        --max-time 20 \
        --connect-timeout 10 \
        --write-out '\nHTTP_STATUS=%{http_code}\nTIME=%{time_total}\n' \
        "http://${ALB_DNS}/health" \
        > "$CURL_HEALTH" 2>&1; then

        cat "$CURL_HEALTH" | tee -a "$REPORT"

        HEALTH_STATUS="$(
            grep 'HTTP_STATUS=' "$CURL_HEALTH" \
                | tail -n 1 \
                | cut -d= -f2
        )"

        if [[ "$HEALTH_STATUS" == "200" ]]; then
            pass "GET /health respondeu HTTP 200."
        else
            fail "GET /health respondeu HTTP $HEALTH_STATUS."
        fi

    else
        fail "curl /health falhou."
        cat "$CURL_HEALTH" | tee -a "$REPORT"
    fi
fi

# -----------------------------------------------------------------------------
# 29. FRONTEND NO ECS VS CÓDIGO LOCAL
# -----------------------------------------------------------------------------

section "29. CONSISTÊNCIA AWS VS CÓDIGO"

if [[ -n "$TASK_DEFINITION" && "$TASK_DEFINITION" != "None" ]]; then

    AWS_IMAGE="$(
        aws ecs describe-task-definition \
            --task-definition "$TASK_DEFINITION" \
            --region "$AWS_REGION" \
            --query 'taskDefinition.containerDefinitions[?name==`frontend`].image | [0]' \
            --output text \
            2>/dev/null || true
    )"

    log "Código Docker esperado: frontend local."
    log "Imagem AWS: $AWS_IMAGE"

    if [[ "$AWS_IMAGE" == *"cloudstart-dev-frontend:v0.1.0" ]]; then
        pass "AWS usa cloudstart-dev-frontend:v0.1.0."
    else
        warn "AWS não está usando exatamente cloudstart-dev-frontend:v0.1.0."
    fi
fi

# -----------------------------------------------------------------------------
# 30. ANÁLISE DE DEPENDÊNCIA DO BACKEND
# -----------------------------------------------------------------------------

section "30. DEPENDÊNCIA FRONTEND -> BACKEND"

if [[ -f "$NGINX_CONF" ]]; then

    BACKEND_REFS="$(
        grep -Ein \
            'backend|proxy_pass|upstream' \
            "$NGINX_CONF" \
            2>/dev/null || true
    )"

    if [[ -n "$BACKEND_REFS" ]]; then

        warn "Frontend possui dependência direta de backend em nginx.conf."

        echo "$BACKEND_REFS" | tee -a "$REPORT"

        if echo "$BACKEND_REFS" \
            | grep -Eq 'backend:8000'; then

            fail "Frontend referencia backend:8000 diretamente."
            fail "No ECS, frontend/backend são tasks separadas; essa referência precisa ser eliminada ou validada explicitamente."
        fi

    else
        pass "Frontend não possui referência direta a backend no nginx.conf."
    fi
fi

# -----------------------------------------------------------------------------
# 31. DOCKERFILE / PROCESSO PRINCIPAL
# -----------------------------------------------------------------------------

section "31. DOCKERFILE / PROCESSO"

if [[ -f "apps/frontend/Dockerfile" ]]; then

    echo "Entrypoint/CMD do Dockerfile:" | tee -a "$REPORT"

    grep -nEi \
        '^FROM|^ENTRYPOINT|^CMD|^USER|^EXPOSE|^COPY|^HEALTHCHECK' \
        apps/frontend/Dockerfile \
        | tee -a "$REPORT"

    if grep -qE '^CMD[[:space:]]+.*nginx' apps/frontend/Dockerfile; then
        pass "CMD do frontend inicia Nginx."
    else
        warn "CMD do Dockerfile não foi identificado como Nginx."
    fi
fi

# -----------------------------------------------------------------------------
# 32. CONTAINER HEALTHCHECK
# -----------------------------------------------------------------------------

section "32. CONTAINER HEALTHCHECK"

if [[ -n "$TASK_DEFINITION" && "$TASK_DEFINITION" != "None" ]]; then

    HEALTHCHECK_FILE="$AUDIT_DIR/frontend-healthcheck.json"

    aws ecs describe-task-definition \
        --task-definition "$TASK_DEFINITION" \
        --region "$AWS_REGION" \
        --query 'taskDefinition.containerDefinitions[?name==`frontend`].healthCheck' \
        --output json \
        > "$HEALTHCHECK_FILE" 2>&1 || true

    cat "$HEALTHCHECK_FILE" | tee -a "$REPORT"

    if grep -q 'null' "$HEALTHCHECK_FILE"; then
        warn "Frontend task definition não possui container health check explícito."
    else
        pass "Frontend possui container health check."
    fi
fi

# -----------------------------------------------------------------------------
# 33. LOAD BALANCER MAPEAMENTO
# -----------------------------------------------------------------------------

section "33. LOAD BALANCER MAPPING"

if [[ -n "$CLUSTER" ]]; then

    aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$EXPECTED_SERVICE" \
        --region "$AWS_REGION" \
        --query 'services[0].loadBalancers[].{
            TargetGroup:targetGroupArn,
            Container:containerName,
            ContainerPort:containerPort
        }' \
        --output table \
        | tee -a "$REPORT"

    FRONT_PORT="$(
        aws ecs describe-services \
            --cluster "$CLUSTER" \
            --services "$EXPECTED_SERVICE" \
            --region "$AWS_REGION" \
            --query 'services[0].loadBalancers[0].containerPort' \
            --output text \
            2>/dev/null || true
    )"

    log "Frontend container port: $FRONT_PORT"

    if [[ "$FRONT_PORT" == "80" ]]; then
        pass "Frontend ECS está publicado na porta 80."
    else
        fail "Frontend ECS está usando porta inesperada: $FRONT_PORT."
    fi
fi

# -----------------------------------------------------------------------------
# 34. TASK PLACEMENT / RESOURCE
# -----------------------------------------------------------------------------

section "34. TASK PLACEMENT / RECURSOS"

if [[ -n "$CLUSTER" ]]; then

    aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$EXPECTED_SERVICE" \
        --region "$AWS_REGION" \
        --query 'services[0].events[0:30].message' \
        --output text \
        | tee "$AUDIT_DIR/task-placement-events.txt" "$REPORT"

    if grep -Eqi \
        'RESOURCE:|insufficient|memory|cpu|capacity|unable to place' \
        "$AUDIT_DIR/task-placement-events.txt"; then

        warn "Eventos de placement/resource apareceram."
    else
        pass "Nenhum erro óbvio de placement/resource encontrado."
    fi
fi

# -----------------------------------------------------------------------------
# 35. ECS NETWORK CONFIGURATION
# -----------------------------------------------------------------------------

section "35. ECS NETWORK"

if [[ -n "$CLUSTER" ]]; then

    aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$EXPECTED_SERVICE" \
        --region "$AWS_REGION" \
        --query 'services[0].networkConfiguration.awsvpcConfiguration' \
        --output json \
        | tee -a "$REPORT"

fi

# -----------------------------------------------------------------------------
# 36. FRONTEND TASKS RUNNING/PENDING AGORA
# -----------------------------------------------------------------------------

section "36. TASKS ATUAIS"

RUNNING_TASKS="$(
    aws ecs list-tasks \
        --cluster "$CLUSTER" \
        --service-name "$EXPECTED_SERVICE" \
        --desired-status RUNNING \
        --region "$AWS_REGION" \
        --query 'taskArns[]' \
        --output text \
        2>/dev/null || true
)"

PENDING_TASKS="$(
    aws ecs list-tasks \
        --cluster "$CLUSTER" \
        --service-name "$EXPECTED_SERVICE" \
        --desired-status PENDING \
        --region "$AWS_REGION" \
        --query 'taskArns[]' \
        --output text \
        2>/dev/null || true
)"

if [[ -n "$RUNNING_TASKS" ]]; then
    pass "Existem tasks RUNNING."

    aws ecs describe-tasks \
        --cluster "$CLUSTER" \
        --tasks $RUNNING_TASKS \
        --region "$AWS_REGION" \
        --query 'tasks[].{
            Task:taskArn,
            Last:lastStatus,
            Desired:desiredStatus,
            Health:healthStatus,
            Containers:containers[].{
                Name:name,
                Last:lastStatus,
                Health:healthStatus,
                ExitCode:exitCode,
                Reason:reason
            }
        }' \
        --output json \
        | tee -a "$REPORT"
else
    fail "Não existem tasks frontend RUNNING."
fi

if [[ -n "$PENDING_TASKS" ]]; then
    warn "Existem tasks frontend PENDING."

    aws ecs describe-tasks \
        --cluster "$CLUSTER" \
        --tasks $PENDING_TASKS \
        --region "$AWS_REGION" \
        --query 'tasks[].{
            Task:taskArn,
            Last:lastStatus,
            Desired:desiredStatus,
            Health:healthStatus,
            Containers:containers[].{
                Name:name,
                Last:lastStatus,
                Health:healthStatus,
                ExitCode:exitCode,
                Reason:reason
            }
        }' \
        --output json \
        | tee -a "$REPORT"
else
    info "Nenhuma task frontend PENDING."
fi

# -----------------------------------------------------------------------------
# 37. CLASSIFICAÇÃO AUTOMÁTICA DA CAUSA
# -----------------------------------------------------------------------------

section "37. CLASSIFICAÇÃO AUTOMÁTICA DA CAUSA"

ROOT_CAUSE_FOUND=0

echo
echo "### Heurísticas ###" | tee -a "$REPORT"

# A. NGINX CONFIG
if [[ -f "$AUDIT_DIR/nginx-test.txt" ]]; then

    if grep -Eqi \
        'host not found|backend|upstream|emerg' \
        "$AUDIT_DIR/nginx-test.txt"; then

        fail "ROOT CAUSE CANDIDATE: Nginx não consegue carregar a configuração."
        ROOT_CAUSE_FOUND=1
    fi
fi

# B. CLOUDWATCH
if [[ -f "$AUDIT_DIR/frontend-cloudwatch.log" ]]; then

    if grep -Eqi \
        'host not found|upstream|emerg|crit|bind|permission denied' \
        "$AUDIT_DIR/frontend-cloudwatch.log"; then

        fail "ROOT CAUSE CANDIDATE: CloudWatch contém erro de inicialização do Nginx."
        ROOT_CAUSE_FOUND=1
    fi
fi

# C. EXIT CODE
if [[ "$EXIT1_COUNT" -gt 0 ]]; then

    fail "ROOT CAUSE SIGNAL: container frontend termina com ExitCode=1."
    ROOT_CAUSE_FOUND=1
fi

# D. TARGET GROUP
if [[ -f "$TARGET_HEALTH" ]]; then

    if grep -q '"State": "unhealthy"' "$TARGET_HEALTH"; then
        warn "Target Group possui targets unhealthy."
    fi

    if grep -q '"State": "draining"' "$TARGET_HEALTH"; then
        warn "Target Group está drenando targets, compatível com tasks sendo encerradas."
    fi
fi

# E. ECR
if [[ -f "$ECR_IMAGE_FILE" ]]; then

    if grep -q '"imageDetails"' "$ECR_IMAGE_FILE"; then
        pass "ECR image está disponível; CannotPull por ausência da imagem é improvável."
    fi
fi

# -----------------------------------------------------------------------------
# 38. DIAGNÓSTICO LÓGICO
# -----------------------------------------------------------------------------

section "38. DIAGNÓSTICO LÓGICO"

echo
echo "Fluxo observado:" | tee -a "$REPORT"
echo | tee -a "$REPORT"

echo "ECS Desired -> $FRONT_DESIRED" | tee -a "$REPORT"
echo "ECS Running -> $FRONT_RUNNING" | tee -a "$REPORT"
echo "ECS Pending -> $FRONT_PENDING" | tee -a "$REPORT"
echo "AWS Image   -> ${AWS_IMAGE:-<unknown>}" | tee -a "$REPORT"
echo "ECR Tag     -> $EXPECTED_IMAGE_TAG" | tee -a "$REPORT"
echo "ALB         -> ${ALB_DNS:-<unknown>}" | tee -a "$REPORT"
echo "TargetGroup -> ${FRONT_TG_ARN:-<unknown>}" | tee -a "$REPORT"

echo
echo "Interpretação:" | tee -a "$REPORT"

if [[ "$FRONT_RUNNING" == "0" && "$FRONT_DESIRED" != "0" ]]; then

    echo "1. ECS deseja frontend, mas nenhuma task permanece RUNNING." \
        | tee -a "$REPORT"

    if [[ "$EXIT1_COUNT" -gt 0 ]]; then

        echo "2. Existem tasks terminando com ExitCode=1." \
            | tee -a "$REPORT"

        echo "3. Portanto o ALB/TargetGroup é consequência, não causa primária." \
            | tee -a "$REPORT"

    fi

else

    echo "1. Estado atual não corresponde ao padrão Desired>0 / Running=0." \
        | tee -a "$REPORT"

fi

if [[ -f "$AUDIT_DIR/nginx-test.txt" ]]; then

    if grep -Eqi \
        'host not found|backend:8000|upstream|emerg' \
        "$AUDIT_DIR/nginx-test.txt"; then

        echo "4. Forte evidência de falha no startup/configuração do Nginx." \
            | tee -a "$REPORT"
    fi
fi

# -----------------------------------------------------------------------------
# 39. CHECKLIST FINAL
# -----------------------------------------------------------------------------

section "39. CHECKLIST FINAL"

echo
echo "FRONTEND:"
echo "  [ ] Container permanece RUNNING"
echo "  [ ] ExitCode diferente de 1"
echo "  [ ] Nginx inicia"
echo "  [ ] nginx -t OK"
echo "  [ ] Nginx não depende de hostname ECS inexistente"
echo "  [ ] CloudWatch sem erro de startup"
echo "  [ ] Target Group healthy"
echo "  [ ] ALB / retorna 2xx/3xx"
echo "  [ ] /health retorna 200"
echo "  [ ] SG ALB -> Frontend:80"
echo "  [ ] ECR image existe"
echo "  [ ] Task Definition usa imagem correta"
echo "  [ ] Deployment está estável"
echo | tee -a "$REPORT"

# -----------------------------------------------------------------------------
# 40. RESUMO
# -----------------------------------------------------------------------------

section "40. RESUMO FINAL"

echo
echo "==============================================================================" | tee -a "$REPORT"
echo "NOVA FRONTEND FORENSIC AUDIT - SUMMARY" | tee -a "$REPORT"
echo "==============================================================================" | tee -a "$REPORT"

echo -e "${GREEN}PASS : $PASS${RESET}" | tee -a "$REPORT"
echo -e "${YELLOW}WARN : $WARN${RESET}" | tee -a "$REPORT"
echo -e "${RED}FAIL : $FAIL${RESET}" | tee -a "$REPORT"
echo -e "${BLUE}INFO : $INFO${RESET}" | tee -a "$REPORT"

echo
echo "Audit directory:" | tee -a "$REPORT"
echo "$AUDIT_DIR" | tee -a "$REPORT"

echo
echo "Main report:" | tee -a "$REPORT"
echo "$REPORT" | tee -a "$REPORT"

echo
echo "Failures:" | tee -a "$REPORT"
echo "$FAILURES" | tee -a "$REPORT"

echo
echo "Warnings:" | tee -a "$REPORT"
echo "$WARNINGS" | tee -a "$REPORT"

echo
echo "==============================================================================" | tee -a "$REPORT"

# -----------------------------------------------------------------------------
# RESULTADO FINAL
# -----------------------------------------------------------------------------

if [[ "$FAIL" -gt 0 ]]; then

    echo
    echo -e "${RED}FRONTEND AUDIT: FAIL${RESET}"
    echo "Há problemas confirmados."
    echo
    echo "Comando para visualizar somente os FAILs:"
    echo "cat \"$FAILURES\""

    exit 1

elif [[ "$WARN" -gt 0 ]]; then

    echo
    echo -e "${YELLOW}FRONTEND AUDIT: WARNING${RESET}"
    echo "Nenhum FAIL foi confirmado, mas existem pontos para investigação."
    echo
    echo "Comando:"
    echo "cat \"$WARNINGS\""

    exit 2

else

    echo
    echo -e "${GREEN}FRONTEND AUDIT: PASS${RESET}"

    exit 0
fi

