#!/usr/bin/env bash

set -euo pipefail

echo "=============================================================="
echo "NOVA - FIX FRONTEND / NGINX"
echo "=============================================================="

# ------------------------------------------------------------------
# 1. Verificações
# ------------------------------------------------------------------

if [[ ! -f apps/frontend/Dockerfile ]]; then
    echo "[FAIL] Execute este script na raiz do NOVA."
    exit 1
fi

if [[ ! -f apps/frontend/nginx.conf ]]; then
    echo "[FAIL] apps/frontend/nginx.conf não encontrado."
    exit 1
fi

if [[ ! -f docker-compose.yml ]]; then
    echo "[FAIL] docker-compose.yml não encontrado."
    exit 1
fi

echo "[PASS] Estrutura do repositório encontrada."

# ------------------------------------------------------------------
# 2. Backup
# ------------------------------------------------------------------

BACKUP_DIR="/tmp/nova-frontend-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

cp apps/frontend/nginx.conf "$BACKUP_DIR/nginx.conf"
cp docker-compose.yml "$BACKUP_DIR/docker-compose.yml"

echo "[PASS] Backup criado em:"
echo "       $BACKUP_DIR"

# ------------------------------------------------------------------
# 3. nginx.conf = PRODUÇÃO / AWS
# ------------------------------------------------------------------

cat > apps/frontend/nginx.conf <<'NGINX'
server {
    listen 80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    location = /health {
        access_log off;
        default_type text/plain;
        return 200 'ok';
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX

echo "[PASS] nginx.conf convertido para configuração AWS/prod."

# ------------------------------------------------------------------
# 4. nginx.local.conf = DOCKER COMPOSE
# ------------------------------------------------------------------

cat > apps/frontend/nginx.local.conf <<'NGINX'
server {
    listen 80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    location = /health {
        access_log off;
        default_type text/plain;
        return 200 'ok';
    }

    location = /api {
        proxy_pass http://backend:8000/api;

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /api/ {
        proxy_pass http://backend:8000/api/;

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX

echo "[PASS] nginx.local.conf criado para Docker Compose."

# ------------------------------------------------------------------
# 5. Docker Compose usa configuração LOCAL
# ------------------------------------------------------------------

python3 <<'PY'
from pathlib import Path

path = Path("docker-compose.yml")
text = path.read_text()

old = """  frontend:
    build:
      context: ./apps/frontend
    ports:
      - "8080:80"
    depends_on:
      - backend
"""

new = """  frontend:
    build:
      context: ./apps/frontend
    ports:
      - "8080:80"
    volumes:
      - ./apps/frontend/nginx.local.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - backend
"""

if old not in text:
    raise SystemExit(
        "[FAIL] Bloco esperado do frontend não foi encontrado em docker-compose.yml."
    )

path.write_text(text.replace(old, new))
print("[PASS] docker-compose.yml configurado para nginx.local.conf.")
PY

# ------------------------------------------------------------------
# 6. Verificar que AWS NÃO possui backend:8000
# ------------------------------------------------------------------

echo
echo "=============================================================="
echo "VALIDAÇÃO DA CONFIGURAÇÃO AWS"
echo "=============================================================="

if grep -nE 'backend:8000|proxy_pass' apps/frontend/nginx.conf; then
    echo "[FAIL] nginx.conf de produção ainda possui proxy para backend."
    exit 1
else
    echo "[PASS] nginx.conf de produção não possui proxy para backend."
fi

# ------------------------------------------------------------------
# 7. Verificar que Compose LOCAL possui backend:8000
# ------------------------------------------------------------------

echo
echo "=============================================================="
echo "VALIDAÇÃO DA CONFIGURAÇÃO LOCAL"
echo "=============================================================="

if grep -nE 'backend:8000|proxy_pass' apps/frontend/nginx.local.conf; then
    echo "[PASS] nginx.local.conf mantém proxy para backend:8000."
else
    echo "[FAIL] nginx.local.conf não contém proxy para backend."
    exit 1
fi

# ------------------------------------------------------------------
# 8. Dockerfile usa nginx.conf de produção
# ------------------------------------------------------------------

echo
echo "=============================================================="
echo "DOCKERFILE"
echo "=============================================================="

grep -nE '^FROM|^COPY|^EXPOSE|^HEALTHCHECK|^CMD|^ENTRYPOINT' \
    apps/frontend/Dockerfile || true

if grep -q 'COPY nginx.conf /etc/nginx/conf.d/default.conf' \
    apps/frontend/Dockerfile; then
    echo "[PASS] Dockerfile usa nginx.conf de produção."
else
    echo "[FAIL] Dockerfile não usa nginx.conf esperado."
    exit 1
fi

# ------------------------------------------------------------------
# 9. Procurar backend:8000 nas configurações relevantes
# ------------------------------------------------------------------

echo
echo "=============================================================="
echo "BUSCA DE REFERÊNCIAS"
echo "=============================================================="

echo
echo "--- nginx.conf ---"
grep -nE 'backend:8000|proxy_pass|upstream' \
    apps/frontend/nginx.conf || echo "[PASS] Nenhuma referência a backend."

echo
echo "--- nginx.local.conf ---"
grep -nE 'backend:8000|proxy_pass|upstream' \
    apps/frontend/nginx.local.conf || true

# ------------------------------------------------------------------
# 10. Mostrar diff
# ------------------------------------------------------------------

echo
echo "=============================================================="
echo "GIT DIFF"
echo "=============================================================="

git diff -- \
    apps/frontend/nginx.conf \
    apps/frontend/nginx.local.conf \
    docker-compose.yml

# ------------------------------------------------------------------
# 11. Terraform validation
# ------------------------------------------------------------------

echo
echo "=============================================================="
echo "TERRAFORM VALIDATE"
echo "=============================================================="

if command -v terraform >/dev/null 2>&1; then
    terraform validate
else
    echo "[WARN] Terraform não disponível neste ambiente."
fi

# ------------------------------------------------------------------
# 12. Docker build da nova versão
# ------------------------------------------------------------------

echo
echo "=============================================================="
echo "DOCKER BUILD"
echo "=============================================================="

IMAGE="cloudstart/frontend:v0.1.1"

docker build \
    -t "$IMAGE" \
    apps/frontend

echo "[PASS] Build concluído: $IMAGE"

# ------------------------------------------------------------------
# 13. Teste nginx -t
# ------------------------------------------------------------------

echo
echo "=============================================================="
echo "NGINX CONFIG TEST"
echo "=============================================================="

docker run \
    --rm \
    "$IMAGE" \
    nginx -t

echo "[PASS] nginx -t da imagem de produção passou."

# ------------------------------------------------------------------
# 14. Inspeção da config final
# ------------------------------------------------------------------

echo
echo "=============================================================="
echo "CONFIG FINAL DENTRO DA IMAGEM"
echo "=============================================================="

docker run \
    --rm \
    "$IMAGE" \
    nginx -T 2>&1 \
    | sed -n '1,220p'

# ------------------------------------------------------------------
# 15. Teste do container
# ------------------------------------------------------------------

echo
echo "=============================================================="
echo "CONTAINER TEST"
echo "=============================================================="

CONTAINER="nova-frontend-test"

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

docker run \
    -d \
    --name "$CONTAINER" \
    -p 18080:80 \
    "$IMAGE"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 3

echo
echo "--- GET /health ---"

curl \
    --fail \
    --silent \
    --show-error \
    http://127.0.0.1:18080/health

echo
echo
echo "[PASS] /health respondeu."

echo
echo "--- GET / ---"

HTTP_CODE="$(
    curl \
        --silent \
        --output /tmp/nova-frontend-root-response.txt \
        --write-out '%{http_code}' \
        http://127.0.0.1:18080/
)"

echo "HTTP $HTTP_CODE"

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "[PASS] / respondeu HTTP 200."
else
    echo "[FAIL] / respondeu HTTP $HTTP_CODE."
    cat /tmp/nova-frontend-root-response.txt || true
    exit 1
fi

# ------------------------------------------------------------------
# 16. Resumo
# ------------------------------------------------------------------

echo
echo "=============================================================="
echo "RESULTADO"
echo "=============================================================="

echo "[PASS] nginx.conf AWS:"
echo "       somente frontend estático"

echo "[PASS] nginx.local.conf:"
echo "       proxy para backend:8000"

echo "[PASS] Docker image:"
echo "       $IMAGE"

echo "[PASS] nginx -t:"
echo "       successful"

echo "[PASS] /health:"
echo "       HTTP 200"

echo "[PASS] /:"
echo "       HTTP 200"

echo
echo "Backup:"
echo "$BACKUP_DIR"

echo
echo "Próximo passo:"
echo "1. revisar git diff"
echo "2. testar docker compose local"
echo "3. pushar $IMAGE para ECR"
echo "4. atualizar task definition ECS"
echo "5. validar Target Group + ALB"

