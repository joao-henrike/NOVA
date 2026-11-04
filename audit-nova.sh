#!/usr/bin/env bash

# ============================================================================
# NOVA / CloudStart - AUDITORIA RIGOROSA
# ============================================================================
#
# Objetivo:
#   Auditar Terraform + AWS + ECS + ALB + ECR + RDS + Secrets + Docker/Compose
#   e deixar evidentes falhas, warnings, drift e inconsistências.
#
# Características:
#   - SOMENTE LEITURA
#   - Não faz terraform apply
#   - Não reinicia serviços
#   - Não cria recursos
#   - Não altera recursos AWS
#   - Não expõe senhas/segredos
#
# Uso:
#   chmod +x audit-nova.sh
#   ./audit-nova.sh
#
# Resultado:
#   ./nova-audit-YYYYMMDD-HHMMSS/
#
# ============================================================================

set -uo pipefail

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
AUDIT_DIR="nova-audit-${TIMESTAMP}"

mkdir -p "$AUDIT_DIR"

REPORT="${AUDIT_DIR}/audit.log"
TERRAFORM_PLAN="${AUDIT_DIR}/terraform-plan.txt"

PASS=0
WARN=0
FAIL=0
INFO=0

# --------------------------------------------------------------------------
# Cores
# --------------------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    RESET=''
fi

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

timestamp_now() {
    date '+%H:%M:%S'
}

section() {
    echo
    echo "======================================================================"
    echo "[$(timestamp_now)] $1"
    echo "======================================================================"
}

pass() {
    PASS=$((PASS + 1))
    echo -e "${GREEN}[PASS]${RESET} $1"
}

warn() {
    WARN=$((WARN + 1))
    echo -e "${YELLOW}[WARN]${RESET} $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo -e "${RED}[FAIL]${RESET} $1"
}

info() {
    INFO=$((INFO + 1))
    echo -e "${BLUE}[INFO]${RESET} $1"
}

run_capture() {
    local outfile="$1"
    shift

    "$@" >"$outfile" 2>&1
    return $?
}

print_and_save() {
    tee -a "$REPORT"
}

require_cmd() {
    local cmd="$1"

    if command -v "$cmd" >/dev/null 2>&1; then
        pass "Comando disponível: $cmd"
        return 0
    else
        fail "Comando ausente: $cmd"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Cabeçalho
# --------------------------------------------------------------------------

{
    echo "NOVA / CloudStart - AUDITORIA"
    echo "Data: $(date -Is)"
    echo "Host: $(hostname)"
    echo "Diretório: $(pwd)"
    echo
} > "$REPORT"

section "1. AMBIENTE LOCAL"

echo "Diretório atual:"
pwd | print_and_save

echo
echo "Usuário:"
whoami | print_and_save

echo
echo "Sistema:"
uname -a | print_and_save

echo
echo "Ferramentas:"
require_cmd terraform
require_cmd aws
require_cmd docker
require_cmd curl
require_cmd git

section "2. VERSÕES"

terraform version 2>&1 | print_and_save
aws --version 2>&1 | print_and_save
docker --version 2>&1 | print_and_save
curl --version 2>&1 | head -n 1 | print_and_save
git --version 2>&1 | print_and_save

section "3. GIT / REPOSITÓRIO"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    pass "Diretório é um repositório Git."

    echo
    echo "Branch atual:"
    BRANCH="$(git branch --show-current 2>/dev/null || true)"
    echo "$BRANCH" | print_and_save

    if [[ "$BRANCH" == "main" ]]; then
        warn "Você está na branch main. Para desenvolvimento do NOVA, isso deve ser revisado."
    else
        pass "Branch atual não é main: ${BRANCH:-<detached>}"
    fi

    echo
    echo "Status Git:"
    git status --short | print_and_save

    echo
    echo "Último commit:"
    git log -1 --oneline | print_and_save
else
    fail "Diretório atual não é um repositório Git."
fi

section "4. ARQUIVOS TERRAFORM"

TF_FILES=(
    backend.tf
    providers.tf
    variables.tf
    outputs.tf
    main.tf
    vpc.tf
    ecs.tf
    ecs_services.tf
    ecr.tf
    iam.tf
    rds.tf
    monitoring.tf
    security_groups.tf
    locals.tf
)

for f in "${TF_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        pass "Arquivo presente: $f"
    else
        fail "Arquivo Terraform ausente: $f"
    fi
done

section "5. TERRAFORM FORMAT"

FMT_OUTPUT="${AUDIT_DIR}/terraform-fmt.txt"

if terraform fmt -check -recursive >"$FMT_OUTPUT" 2>&1; then
    pass "terraform fmt: OK"
else
    warn "terraform fmt detectou arquivos que não estão formatados."
    cat "$FMT_OUTPUT" | print_and_save
fi

section "6. TERRAFORM VALIDATE"

VALIDATE_OUTPUT="${AUDIT_DIR}/terraform-validate.txt"

if terraform validate -no-color >"$VALIDATE_OUTPUT" 2>&1; then
    pass "terraform validate: OK"
else
    fail "terraform validate: FALHOU"
    cat "$VALIDATE_OUTPUT" | print_and_save
fi

section "7. DEPRECATIONS / WARNINGS NO CÓDIGO"

echo "Busca por dynamodb_table:"
grep -Rni \
    --exclude-dir=.terraform \
    --exclude-dir=.git \
    --exclude='*.png' \
    'dynamodb_table' . \
    > "${AUDIT_DIR}/dynamodb_table.txt" 2>&1 || true

cat "${AUDIT_DIR}/dynamodb_table.txt" | print_and_save

if grep -Rni \
    --exclude-dir=.terraform \
    --exclude-dir=.git \
    --exclude='*.png' \
    'dynamodb_table' . >/dev/null 2>&1; then
    warn "Ainda existem referências a dynamodb_table no repositório."
else
    pass "Nenhuma referência a dynamodb_table encontrada."
fi

echo
echo "Busca por data.aws_region.current.name:"
grep -Rni \
    --exclude-dir=.terraform \
    --exclude-dir=.git \
    --exclude='*.png' \
    'data\.aws_region\.current\.name' . \
    > "${AUDIT_DIR}/aws-region-name.txt" 2>&1 || true

cat "${AUDIT_DIR}/aws-region-name.txt" | print_and_save

if grep -Rni \
    --exclude-dir=.terraform \
    --exclude-dir=.git \
    --exclude='*.png' \
    'data\.aws_region\.current\.name' . >/dev/null 2>&1; then
    warn "Ainda existe uso de data.aws_region.current.name."
else
    pass "Nenhum uso encontrado de data.aws_region.current.name."
fi

section "8. ZABBIX - CONSISTÊNCIA DAS TAGS"

echo "Todas as referências Zabbix:"
grep -Rni \
    --exclude-dir=.terraform \
    --exclude-dir=.git \
    --exclude='*.png' \
    -E 'zabbix-server-pgsql|zabbix-web-nginx-pgsql' . \
    > "${AUDIT_DIR}/zabbix-references.txt" 2>&1 || true

cat "${AUDIT_DIR}/zabbix-references.txt" | print_and_save

echo
echo "Busca por tags 8.0:"
if grep -Rni \
    --exclude-dir=.terraform \
    --exclude-dir=.git \
    --exclude='*.png' \
    'alpine-8\.0-latest' . >/dev/null 2>&1; then

    fail "Ainda existem referências a alpine-8.0-latest."
    grep -Rni \
        --exclude-dir=.terraform \
        --exclude-dir=.git \
        --exclude='*.png' \
        'alpine-8\.0-latest' . | print_and_save
else
    pass "Nenhuma referência a alpine-8.0-latest."
fi

echo
echo "Busca por tags 7.4:"
if grep -Rni \
    --exclude-dir=.terraform \
    --exclude-dir=.git \
    --exclude='*.png' \
    'alpine-7\.4-latest' . >/dev/null 2>&1; then

    pass "Referências a alpine-7.4-latest encontradas."
    grep -Rni \
        --exclude-dir=.terraform \
        --exclude-dir=.git \
        --exclude='*.png' \
        'alpine-7\.4-latest' . | print_and_save
else
    fail "Nenhuma referência a alpine-7.4-latest encontrada."
fi

section "9. BACKEND TERRAFORM"

if [[ -f backend.tf ]]; then

    echo "backend.tf:"
    cat backend.tf | print_and_save

    if grep -q 'use_lockfile[[:space:]]*=' backend.tf; then
        pass "backend.tf usa use_lockfile."
    else
        fail "backend.tf não contém use_lockfile."
    fi

    if grep -q 'dynamodb_table[[:space:]]*=' backend.tf; then
        warn "backend.tf ainda contém dynamodb_table."
    fi
fi

section "10. DOCKER COMPOSE"

COMPOSE_CMD=""

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
    pass "Docker Compose plugin disponível."
    docker compose version | print_and_save
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
    pass "docker-compose clássico disponível."
    docker-compose --version | print_and_save
else
    warn "Nenhum Docker Compose encontrado."
    info "A auditoria continuará sem executar validação do Compose."
fi

section "11. DOCKER / IMAGENS ZABBIX"

ZABBIX_SERVER_IMAGE="zabbix/zabbix-server-pgsql:alpine-7.4-latest"
ZABBIX_WEB_IMAGE="zabbix/zabbix-web-nginx-pgsql:alpine-7.4-latest"

echo "Verificando imagem:"
echo "$ZABBIX_SERVER_IMAGE" | print_and_save

if docker image inspect "$ZABBIX_SERVER_IMAGE" >/dev/null 2>&1; then
    pass "Imagem local existe: $ZABBIX_SERVER_IMAGE"
else
    warn "Imagem local não existe: $ZABBIX_SERVER_IMAGE"
fi

echo
echo "Verificando imagem:"
echo "$ZABBIX_WEB_IMAGE" | print_and_save

if docker image inspect "$ZABBIX_WEB_IMAGE" >/dev/null 2>&1; then
    pass "Imagem local existe: $ZABBIX_WEB_IMAGE"
else
    warn "Imagem local não existe: $ZABBIX_WEB_IMAGE"
fi

echo
echo "Teste de manifest Zabbix:"

if docker manifest inspect "$ZABBIX_SERVER_IMAGE" >/dev/null 2>&1; then
    pass "Manifest válido: $ZABBIX_SERVER_IMAGE"
else
    fail "Manifest inválido/inacessível: $ZABBIX_SERVER_IMAGE"
fi

if docker manifest inspect "$ZABBIX_WEB_IMAGE" >/dev/null 2>&1; then
    pass "Manifest válido: $ZABBIX_WEB_IMAGE"
else
    fail "Manifest inválido/inacessível: $ZABBIX_WEB_IMAGE"
fi

section "12. DOCKER COMPOSE MONITORING"

if [[ -n "$COMPOSE_CMD" && -f docker-compose.monitoring.yml ]]; then

    COMPOSE_MONITOR_OUTPUT="${AUDIT_DIR}/compose-monitoring-config.txt"

    if $COMPOSE_CMD -f docker-compose.monitoring.yml config --quiet \
        >"$COMPOSE_MONITOR_OUTPUT" 2>&1; then

        pass "docker-compose.monitoring.yml: sintaxe/configuração OK."
    else
        fail "docker-compose.monitoring.yml: validação falhou."
        cat "$COMPOSE_MONITOR_OUTPUT" | print_and_save
    fi
elif [[ ! -f docker-compose.monitoring.yml ]]; then
    fail "docker-compose.monitoring.yml não encontrado."
fi

section "13. AWS CREDENCIAIS / IDENTIDADE"

AWS_ID_OUTPUT="${AUDIT_DIR}/aws-identity.json"

if aws sts get-caller-identity >"$AWS_ID_OUTPUT" 2>&1; then
    pass "AWS CLI autenticado."

    cat "$AWS_ID_OUTPUT" | print_and_save

    ACCOUNT_ID="$(aws sts get-caller-identity \
        --query 'Account' \
        --output text 2>/dev/null || true)"

    CALLER_ARN="$(aws sts get-caller-identity \
        --query 'Arn' \
        --output text 2>/dev/null || true)"

    echo "Account: $ACCOUNT_ID" | print_and_save
    echo "Caller:  $CALLER_ARN" | print_and_save
else
    fail "AWS CLI não conseguiu executar sts get-caller-identity."
    cat "$AWS_ID_OUTPUT" | print_and_save
fi

section "14. TERRAFORM OUTPUTS"

if terraform output >/dev/null 2>&1; then
    terraform output -no-color | print_and_save

    ALB_DNS="$(terraform output -raw alb_dns_name 2>/dev/null || true)"
    CLUSTER="$(terraform output -raw ecs_cluster_name 2>/dev/null || true)"
    AWS_REGION="$(terraform output -raw aws_region 2>/dev/null || true)"

    if [[ -z "$AWS_REGION" ]]; then
        AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
    fi

    export AWS_REGION

    info "ALB_DNS=${ALB_DNS:-<indisponível>}"
    info "CLUSTER=${CLUSTER:-<indisponível>}"
    info "AWS_REGION=${AWS_REGION:-<indisponível>}"
else
    fail "Não foi possível obter terraform outputs."
    ALB_DNS=""
    CLUSTER=""
    AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
fi

section "15. AWS / ECS CLUSTER"

if [[ -n "$CLUSTER" ]]; then

    ECS_CLUSTER_OUTPUT="${AUDIT_DIR}/ecs-cluster.txt"

    if aws ecs describe-clusters \
        --clusters "$CLUSTER" \
        --region "$AWS_REGION" \
        --query 'clusters[].{Name:clusterName,Status:status,ActiveServices:activeServicesCount,RunningTasks:runningTasksCount}' \
        --output table >"$ECS_CLUSTER_OUTPUT" 2>&1; then

        cat "$ECS_CLUSTER_OUTPUT" | print_and_save
        pass "ECS cluster consultável."
    else
        fail "Falha ao consultar ECS cluster."
        cat "$ECS_CLUSTER_OUTPUT" | print_and_save
    fi
fi

section "16. ECS / SERVICES"

SERVICES=(
    cloudstart-dev-frontend
    cloudstart-dev-backend
    cloudstart-dev-monitoring
)

SERVICES_OUTPUT="${AUDIT_DIR}/ecs-services.json"

if [[ -n "$CLUSTER" ]]; then

    if aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "${SERVICES[@]}" \
        --region "$AWS_REGION" \
        --output json >"$SERVICES_OUTPUT" 2>&1; then

        cat "$SERVICES_OUTPUT" | print_and_save

        echo
        echo "Resumo dos serviços:"

        aws ecs describe-services \
            --cluster "$CLUSTER" \
            --services "${SERVICES[@]}" \
            --region "$AWS_REGION" \
            --query 'services[].{Service:serviceName,Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount,Deployments:length(deployments)}' \
            --output table | print_and_save

        # Frontend
        FRONT_RUNNING="$(aws ecs describe-services \
            --cluster "$CLUSTER" \
            --services cloudstart-dev-frontend \
            --region "$AWS_REGION" \
            --query 'services[0].runningCount' \
            --output text 2>/dev/null || echo "0")"

        FRONT_DESIRED="$(aws ecs describe-services \
            --cluster "$CLUSTER" \
            --services cloudstart-dev-frontend \
            --region "$AWS_REGION" \
            --query 'services[0].desiredCount' \
            --output text 2>/dev/null || echo "0")"

        if [[ "$FRONT_RUNNING" == "$FRONT_DESIRED" && "$FRONT_DESIRED" != "0" ]]; then
            pass "Frontend ECS: running=$FRONT_RUNNING desired=$FRONT_DESIRED"
        else
            fail "Frontend ECS inconsistente: running=$FRONT_RUNNING desired=$FRONT_DESIRED"
        fi

        # Backend
        BACK_RUNNING="$(aws ecs describe-services \
            --cluster "$CLUSTER" \
            --services cloudstart-dev-backend \
            --region "$AWS_REGION" \
            --query 'services[0].runningCount' \
            --output text 2>/dev/null || echo "0")"

        BACK_DESIRED="$(aws ecs describe-services \
            --cluster "$CLUSTER" \
            --services cloudstart-dev-backend \
            --region "$AWS_REGION" \
            --query 'services[0].desiredCount' \
            --output text 2>/dev/null || echo "0")"

        if [[ "$BACK_RUNNING" == "$BACK_DESIRED" && "$BACK_DESIRED" != "0" ]]; then
            pass "Backend ECS: running=$BACK_RUNNING desired=$BACK_DESIRED"
        else
            fail "Backend ECS inconsistente: running=$BACK_RUNNING desired=$BACK_DESIRED"
        fi

        # Monitoring
        MON_RUNNING="$(aws ecs describe-services \
            --cluster "$CLUSTER" \
            --services cloudstart-dev-monitoring \
            --region "$AWS_REGION" \
            --query 'services[0].runningCount' \
            --output text 2>/dev/null || echo "0")"

        MON_DESIRED="$(aws ecs describe-services \
            --cluster "$CLUSTER" \
            --services cloudstart-dev-monitoring \
            --region "$AWS_REGION" \
            --query 'services[0].desiredCount' \
            --output text 2>/dev/null || echo "0")"

        if [[ "$MON_RUNNING" == "$MON_DESIRED" && "$MON_DESIRED" != "0" ]]; then
            pass "Monitoring ECS: running=$MON_RUNNING desired=$MON_DESIRED"
        else
            fail "Monitoring ECS inconsistente: running=$MON_RUNNING desired=$MON_DESIRED"
        fi
    else
        fail "describe-services falhou."
        cat "$SERVICES_OUTPUT" | print_and_save
    fi
fi

section "17. ECS / SERVICE EVENTS"

for SERVICE in "${SERVICES[@]}"; do

    EVENT_FILE="${AUDIT_DIR}/${SERVICE}-events.txt"

    echo
    echo "### $SERVICE ###"

    if aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$SERVICE" \
        --region "$AWS_REGION" \
        --query 'services[0].events[0:15].message' \
        --output text >"$EVENT_FILE" 2>&1; then

        cat "$EVENT_FILE" | print_and_save

        if grep -Eqi \
            'CannotPullContainerError|unable to place|failed|essential container|health check|RESOURCE:' \
            "$EVENT_FILE"; then

            fail "$SERVICE possui eventos indicando falha."
        else
            pass "$SERVICE não apresentou erro crítico nos últimos eventos."
        fi
    else
        fail "Não foi possível obter eventos de $SERVICE."
    fi
done

section "18. ECS / TASKS STOPPED"

for SERVICE in "${SERVICES[@]}"; do

    STOPPED_FILE="${AUDIT_DIR}/${SERVICE}-stopped.txt"

    echo
    echo "### $SERVICE ###"

    TASKS="$(aws ecs list-tasks \
        --cluster "$CLUSTER" \
        --service-name "$SERVICE" \
        --desired-status STOPPED \
        --region "$AWS_REGION" \
        --query 'taskArns[0:10]' \
        --output text 2>/dev/null || true)"

    if [[ -z "$TASKS" ]]; then
        info "$SERVICE: nenhuma task STOPPED retornada."
        continue
    fi

    if aws ecs describe-tasks \
        --cluster "$CLUSTER" \
        --tasks $TASKS \
        --region "$AWS_REGION" \
        --query 'tasks[].{
          Task:taskArn,
          StopCode:stopCode,
          StoppedReason:stoppedReason,
          Containers:containers[].{
            Name:name,
            LastStatus:lastStatus,
            ExitCode:exitCode,
            Reason:reason
          }
        }' \
        --output json >"$STOPPED_FILE" 2>&1; then

        cat "$STOPPED_FILE" | print_and_save

        if grep -Eqi \
            'CannotPullContainerError|CannotPull|EssentialContainerExited|failed|error|health' \
            "$STOPPED_FILE"; then

            fail "$SERVICE possui tasks STOPPED com indicação de erro."
        else
            warn "$SERVICE possui tasks STOPPED. Revisar evidência acima."
        fi
    else
        fail "Falha ao descrever tasks STOPPED de $SERVICE."
    fi
done

section "19. ECS / TASK DEFINITIONS / IMAGENS"

for SERVICE in "${SERVICES[@]}"; do

    echo
    echo "### $SERVICE ###"

    TD_ARN="$(aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$SERVICE" \
        --region "$AWS_REGION" \
        --query 'services[0].taskDefinition' \
        --output text 2>/dev/null || true)"

    if [[ -z "$TD_ARN" || "$TD_ARN" == "None" ]]; then
        fail "$SERVICE não possui task definition identificável."
        continue
    fi

    echo "Task definition: $TD_ARN" | print_and_save

    TD_FILE="${AUDIT_DIR}/${SERVICE}-task-definition.json"

    if aws ecs describe-task-definition \
        --task-definition "$TD_ARN" \
        --region "$AWS_REGION" \
        --output json >"$TD_FILE" 2>&1; then

        # Exibe apenas campos não secretos relevantes.
        aws ecs describe-task-definition \
            --task-definition "$TD_ARN" \
            --region "$AWS_REGION" \
            --query 'taskDefinition.containerDefinitions[].{
              Name:name,
              Image:image,
              CPU:cpu,
              Memory:memory,
              Essential:essential,
              HealthCheck:healthCheck
            }' \
            --output json | print_and_save

        IMAGES="$(aws ecs describe-task-definition \
            --task-definition "$TD_ARN" \
            --region "$AWS_REGION" \
            --query 'taskDefinition.containerDefinitions[].image' \
            --output text 2>/dev/null || true)"

        echo "Images:"
        echo "$IMAGES" | print_and_save

        if [[ "$SERVICE" == "cloudstart-dev-monitoring" ]]; then

            if echo "$IMAGES" | grep -q 'alpine-8\.0-latest'; then
                fail "Monitoring ainda usa imagem Zabbix 8.0 inexistente."
            fi

            if echo "$IMAGES" | grep -q 'alpine-7\.4-latest'; then
                pass "Monitoring task definition usa Zabbix 7.4."
            else
                warn "Monitoring não está usando explicitamente Zabbix 7.4."
            fi
        fi
    else
        fail "Falha ao consultar task definition de $SERVICE."
    fi
done

section "20. ALB / DNS"

if [[ -n "$ALB_DNS" ]]; then

    echo "ALB DNS: $ALB_DNS" | print_and_save

    if getent hosts "$ALB_DNS" >/dev/null 2>&1; then
        pass "DNS do ALB resolve."
        getent hosts "$ALB_DNS" | print_and_save
    else
        fail "DNS do ALB não resolve."
    fi
else
    fail "ALB_DNS não disponível."
fi

section "21. TARGET GROUPS / HEALTH"

TG_NAMES=(
    cloudstart-dev-frontend-tg
    cloudstart-dev-backend-tg
    cloudstart-dev-grafana-tg
)

for TG_NAME in "${TG_NAMES[@]}"; do

    echo
    echo "### $TG_NAME ###"

    TG_ARN="$(aws elbv2 describe-target-groups \
        --names "$TG_NAME" \
        --region "$AWS_REGION" \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text 2>/dev/null || true)"

    if [[ -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then
        fail "Target group não encontrado: $TG_NAME"
        continue
    fi

    pass "Target group encontrado: $TG_NAME"

    TG_FILE="${AUDIT_DIR}/${TG_NAME}-health.txt"

    if aws elbv2 describe-target-health \
        --target-group-arn "$TG_ARN" \
        --region "$AWS_REGION" \
        --output table >"$TG_FILE" 2>&1; then

        cat "$TG_FILE" | print_and_save

        if grep -Eqi 'healthy' "$TG_FILE"; then
            pass "$TG_NAME possui target healthy."
        else
            fail "$TG_NAME não possui target healthy."
        fi
    else
        fail "Falha ao consultar health do target group $TG_NAME."
        cat "$TG_FILE" | print_and_save
    fi
done

section "22. ALB / LISTENERS"

aws elbv2 describe-listeners \
    --load-balancer-arn "$(
        aws elbv2 describe-load-balancers \
            --names cloudstart-dev-alb \
            --region "$AWS_REGION" \
            --query 'LoadBalancers[0].LoadBalancerArn' \
            --output text 2>/dev/null || true
    )" \
    --region "$AWS_REGION" \
    --output table 2>&1 | print_and_save

section "23. ALB / HTTP REAL"

if [[ -n "$ALB_DNS" ]]; then

    declare -A ENDPOINTS
    ENDPOINTS["frontend"]="/"
    ENDPOINTS["backend-health"]="/api/health"
    ENDPOINTS["backend-info"]="/api/info"
    ENDPOINTS["backend-db"]="/api/health/db"

    for NAME in "${!ENDPOINTS[@]}"; do

        PATH_TEST="${ENDPOINTS[$NAME]}"
        HTTP_FILE="${AUDIT_DIR}/curl-${NAME}.txt"

        echo
        echo "### GET $PATH_TEST ###"

        if curl \
            --silent \
            --show-error \
            --max-time 20 \
            --connect-timeout 10 \
            --write-out '\nHTTP_STATUS=%{http_code}\nTIME_TOTAL=%{time_total}\n' \
            "http://${ALB_DNS}${PATH_TEST}" \
            >"$HTTP_FILE" 2>&1; then

            cat "$HTTP_FILE" | print_and_save

            STATUS="$(grep 'HTTP_STATUS=' "$HTTP_FILE" | cut -d= -f2 | tail -n1)"

            if [[ "$STATUS" =~ ^2|^3 ]]; then
                pass "$NAME respondeu HTTP $STATUS"
            elif [[ "$STATUS" == "000" ]]; then
                fail "$NAME não estabeleceu conexão HTTP."
            else
                fail "$NAME respondeu HTTP $STATUS"
            fi
        else
            fail "curl falhou para $PATH_TEST"
            cat "$HTTP_FILE" | print_and_save
        fi
    done
else
    fail "Não foi possível testar ALB porque ALB_DNS está vazio."
fi

section "24. ECR"

for REPO in cloudstart-dev-frontend cloudstart-dev-backend; do

    echo
    echo "### ECR: $REPO ###"

    ECR_FILE="${AUDIT_DIR}/${REPO}-ecr.txt"

    if aws ecr describe-repositories \
        --repository-names "$REPO" \
        --region "$AWS_REGION" \
        --output json >"$ECR_FILE" 2>&1; then

        pass "ECR repository existe: $REPO"

        aws ecr describe-images \
            --repository-name "$REPO" \
            --region "$AWS_REGION" \
            --query 'imageDetails[].{Tags:imageTags,Digest:imageDigest,Pushed:imagePushedAt}' \
            --output table | print_and_save

        if aws ecr describe-images \
            --repository-name "$REPO" \
            --region "$AWS_REGION" \
            --query 'imageDetails[?contains(imageTags, `v0.1.0`)].imageDigest' \
            --output text 2>/dev/null | grep -q 'sha256:'; then

            pass "$REPO possui v0.1.0."
        else
            fail "$REPO não possui v0.1.0."
        fi
    else
        fail "ECR repository inexistente/inacessível: $REPO"
        cat "$ECR_FILE" | print_and_save
    fi
done

section "25. RDS"

RDS_FILE="${AUDIT_DIR}/rds.json"

if aws rds describe-db-instances \
    --region "$AWS_REGION" \
    --output json >"$RDS_FILE" 2>&1; then

    aws rds describe-db-instances \
        --region "$AWS_REGION" \
        --query 'DBInstances[?starts_with(DBInstanceIdentifier, `cloudstart-dev`)].{
          Identifier:DBInstanceIdentifier,
          Status:DBInstanceStatus,
          Engine:Engine,
          Version:EngineVersion,
          MultiAZ:MultiAZ,
          PubliclyAccessible:PubliclyAccessible,
          Endpoint:Endpoint.Address,
          Port:Endpoint.Port
        }' \
        --output table | print_and_save

    for DB_IDENTIFIER in \
        cloudstart-dev-db \
        cloudstart-dev-monitoring-db; do

        STATUS="$(aws rds describe-db-instances \
            --db-instance-identifier "$DB_IDENTIFIER" \
            --region "$AWS_REGION" \
            --query 'DBInstances[0].DBInstanceStatus' \
            --output text 2>/dev/null || true)"

        if [[ "$STATUS" == "available" ]]; then
            pass "RDS $DB_IDENTIFIER: available"
        else
            fail "RDS $DB_IDENTIFIER: status=${STATUS:-<indisponível>}"
        fi
    done
else
    fail "Falha ao consultar RDS."
    cat "$RDS_FILE" | print_and_save
fi

section "26. SECRETS MANAGER"

SECRET_FILE="${AUDIT_DIR}/secrets.json"

if aws secretsmanager list-secrets \
    --region "$AWS_REGION" \
    --output json >"$SECRET_FILE" 2>&1; then

    if grep -q 'cloudstart-dev/monitoring/grafana-admin' "$SECRET_FILE"; then
        pass "Secret do Grafana encontrado."
    else
        warn "Secret esperado do Grafana não foi localizado pelo filtro textual."
    fi

    echo "Secrets relevantes (somente ARN/name, sem valores):"
    aws secretsmanager list-secrets \
        --region "$AWS_REGION" \
        --query 'SecretList[?contains(Name, `cloudstart-dev`)].{Name:Name,ARN:ARN}' \
        --output table | print_and_save
else
    fail "Falha ao consultar Secrets Manager."
fi

section "27. APPLICATION AUTO SCALING"

for SERVICE in \
    cloudstart-dev-frontend \
    cloudstart-dev-backend; do

    RESOURCE_ID="service/${CLUSTER}/${SERVICE}"

    echo
    echo "### $SERVICE ###"

    aws application-autoscaling describe-scalable-targets \
        --service-namespace ecs \
        --resource-ids "$RESOURCE_ID" \
        --region "$AWS_REGION" \
        --query 'ScalableTargets[].{
          ResourceId:ResourceId,
          Min:MinCapacity,
          Max:MaxCapacity,
          SuspendedState:SuspendedState
        }' \
        --output table 2>&1 | print_and_save

    POLICY_COUNT="$(aws application-autoscaling describe-scaling-policies \
        --service-namespace ecs \
        --resource-id "$RESOURCE_ID" \
        --region "$AWS_REGION" \
        --query 'length(ScalingPolicies)' \
        --output text 2>/dev/null || echo "0")"

    if [[ "$POLICY_COUNT" -ge 2 ]]; then
        pass "$SERVICE possui múltiplas políticas de autoscaling."
    else
        warn "$SERVICE possui somente $POLICY_COUNT política(s) de autoscaling."
    fi
done

section "28. TERRAFORM PLAN / DRIFT"

PLAN_STATUS=0

terraform plan \
    -input=false \
    -refresh=true \
    -no-color \
    >"$TERRAFORM_PLAN" 2>&1 || PLAN_STATUS=$?

cat "$TERRAFORM_PLAN" | print_and_save

echo
echo "terraform plan exit code: $PLAN_STATUS" | print_and_save

if grep -Eqi 'Warning:.*Deprecated|Deprecated Parameter|Deprecated value used' "$TERRAFORM_PLAN"; then
    warn "Terraform plan ainda apresenta depreciações/warnings."
    grep -Ein \
        'Warning:.*Deprecated|Deprecated Parameter|Deprecated value used' \
        "$TERRAFORM_PLAN" | print_and_save
else
    pass "Nenhuma depreciação conhecida encontrada na saída do terraform plan."
fi

if grep -q 'No changes' "$TERRAFORM_PLAN"; then
    pass "Terraform: No changes (sem drift detectado)."
else
    warn "Terraform possui mudanças planejadas ou drift. Revisar o plan."
fi

if grep -Eqi 'Error:|failed|Invalid|inconsistent|cannot' "$TERRAFORM_PLAN"; then
    fail "Terraform plan contém mensagens de erro."
fi

section "29. SECURITY GROUPS - TRIAGEM"

SG_FILE="${AUDIT_DIR}/security-groups.txt"

if aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters "Name=group-name,Values=*cloudstart*" \
    --output json >"$SG_FILE" 2>&1; then

    aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=group-name,Values=*cloudstart*" \
        --query 'SecurityGroups[].{
          GroupName:GroupName,
          GroupId:GroupId,
          VpcId:VpcId
        }' \
        --output table | print_and_save

    if grep -q '"FromPort": 0' "$SG_FILE"; then
        warn "Há regras de SG potencialmente amplas; revisar manualmente."
    fi
else
    warn "Não foi possível consultar SGs CloudStart."
fi

section "30. RECURSOS AWS PRINCIPAIS"

echo "VPC:"
aws ec2 describe-vpcs \
    --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=cloudstart" \
    --query 'Vpcs[].{VpcId:VpcId,Cidr:CidrBlock,State:State}' \
    --output table 2>&1 | print_and_save

echo
echo "NAT Gateways:"
aws ec2 describe-nat-gateways \
    --region "$AWS_REGION" \
    --filter "Name=tag:Project,Values=cloudstart" \
    --query 'NatGateways[].{Id:NatGatewayId,State:State,Vpc:VpcId}' \
    --output table 2>&1 | print_and_save

section "31. INCONSISTÊNCIAS IMPORTANTES NO CÓDIGO"

echo
echo "Verificando referências ao estado/documentação antigo:"

if grep -Rni \
    --exclude-dir=.terraform \
    --exclude-dir=.git \
    --exclude='*.png' \
    -E 'two ECS services|two-service' README.md >/dev/null 2>&1; then

    warn "README contém referências antigas a 'two ECS services' que podem conflitar com a existência do monitoring."
else
    pass "Nenhuma referência conhecida de documentação antiga encontrada."
fi

echo
echo "Verificando modo HTTP sem HTTPS:"

if grep -Rni \
    --include='*.tf' \
    'protocol[[:space:]]*=[[:space:]]*"HTTP"' . >/dev/null 2>&1; then

    warn "ALB HTTP está presente. Revisar ACM/HTTPS antes de produção."
else
    pass "Nenhuma configuração HTTP direta detectada pela busca."
fi

section "32. CHECK DE CONSISTÊNCIA LOCAL AWS"

echo
echo "Zabbix no código local:"
grep -Rni \
    --exclude-dir=.terraform \
    --exclude-dir=.git \
    --exclude='*.png' \
    -E 'zabbix-server-pgsql|zabbix-web-nginx-pgsql' . \
    2>/dev/null | print_and_save || true

echo
echo "Zabbix nas task definitions AWS:"

for SERVICE in cloudstart-dev-monitoring; do

    TD_ARN="$(aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$SERVICE" \
        --region "$AWS_REGION" \
        --query 'services[0].taskDefinition' \
        --output text 2>/dev/null || true)"

    if [[ -n "$TD_ARN" && "$TD_ARN" != "None" ]]; then

        aws ecs describe-task-definition \
            --task-definition "$TD_ARN" \
            --region "$AWS_REGION" \
            --query 'taskDefinition.containerDefinitions[].image' \
            --output text 2>&1 | print_and_save
    fi
done

section "33. RESUMO FINAL"
echo
echo "======================================================================"
echo "NOVA AUDIT SUMMARY"
echo "======================================================================"
echo -e "${GREEN}PASS : $PASS${RESET}"
echo -e "${YELLOW}WARN : $WARN${RESET}"
echo -e "${RED}FAIL : $FAIL${RESET}"
echo -e "${BLUE}INFO : $INFO${RESET}"
echo
echo "Diretório completo da auditoria:"
echo "$AUDIT_DIR"
echo
echo "Relatório:"
echo "$REPORT"
echo
echo "Terraform plan:"
echo "$TERRAFORM_PLAN"
echo "======================================================================"

{
    echo
    echo "SUMMARY"
    echo "PASS=$PASS"
    echo "WARN=$WARN"
    echo "FAIL=$FAIL"
    echo "INFO=$INFO"
    echo "AUDIT_DIR=$AUDIT_DIR"
} >> "$REPORT"

if [[ "$FAIL" -gt 0 ]]; then
    echo
    echo -e "${RED}AUDITORIA CONCLUÍDA COM FALHAS.${RESET}"
    echo "Revise os arquivos dentro de:"
    echo "$AUDIT_DIR"
    exit 1
elif [[ "$WARN" -gt 0 ]]; then
    echo
    echo -e "${YELLOW}AUDITORIA CONCLUÍDA SEM FAILS, MAS COM WARNINGS.${RESET}"
    echo "Revise os arquivos dentro de:"
    echo "$AUDIT_DIR"
    exit 2
else
    echo
    echo -e "${GREEN}AUDITORIA CONCLUÍDA SEM FALHAS OU WARNINGS.${RESET}"
    exit 0
fi
