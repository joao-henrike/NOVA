#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_ENV="$ROOT_DIR/config/dev.env"
SECRET_DIR="$ROOT_DIR/.deploy"
ARN_ENV_FILE="$SECRET_DIR/db-secret-arns.env"

[ -f "$CONFIG_ENV" ] || {
  echo "Missing $CONFIG_ENV" >&2
  exit 1
}

set -a
# shellcheck disable=SC1090
source "$CONFIG_ENV"
set +a

command -v aws >/dev/null 2>&1 || {
  echo "AWS CLI is required." >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "jq is required." >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "Python 3 is required." >&2
  exit 1
}

actual_account="$(aws sts get-caller-identity --query Account --output text)"
if [ "$actual_account" != "$EXPECTED_AWS_ACCOUNT_ID" ]; then
  echo "AWS account mismatch: expected $EXPECTED_AWS_ACCOUNT_ID, got $actual_account." >&2
  exit 1
fi

mkdir -p "$SECRET_DIR"
chmod 700 "$SECRET_DIR"

tmp_files=()
cleanup() {
  for file in "${tmp_files[@]}"; do
    rm -f "$file"
  done
}
trap cleanup EXIT

new_secret_file() {
  local path
  path="$(mktemp "$SECRET_DIR/db-password.XXXXXX.json")"
  chmod 600 "$path"
  python3 - "$path" <<'PY'
import json
import secrets
import sys

with open(sys.argv[1], "w", encoding="utf-8") as secret_file:
    json.dump({"password": secrets.token_urlsafe(48)}, secret_file)
    secret_file.write("\n")
PY
  printf '%s\n' "$path"
}

ensure_password_secret() {
  local name="$1"
  local description="$2"
  local arn=""
  local secret_file=""
  local current_file=""
  local error_file=""

  current_file="$(mktemp "$SECRET_DIR/db-current.XXXXXX")"
  error_file="$(mktemp "$SECRET_DIR/db-error.XXXXXX")"
  tmp_files+=("$current_file" "$error_file")

  if arn="$(aws secretsmanager describe-secret \
    --secret-id "$name" \
    --region "$AWS_REGION" \
    --query ARN \
    --output text 2>/dev/null)"; then
    if aws secretsmanager get-secret-value \
      --secret-id "$arn" \
      --region "$AWS_REGION" \
      --query SecretString \
      --output text >"$current_file" 2>"$error_file"; then
      if ! jq -e '.password | type == "string" and length >= 32' "$current_file" >/dev/null; then
        echo "Existing secret $name has an invalid JSON/password structure; refusing to rotate it automatically." >&2
        exit 1
      fi
      rm -f "$current_file" "$error_file"
      printf '%s\n' "$arn"
      return 0
    fi

    if ! grep -q "ResourceNotFoundException" "$error_file"; then
      cat "$error_file" >&2
      echo "Could not read existing secret $name." >&2
      exit 1
    fi

    # A secret container can exist without an AWSCURRENT version.
    secret_file="$(new_secret_file)"
    tmp_files+=("$secret_file")
    aws secretsmanager put-secret-value \
      --secret-id "$arn" \
      --secret-string "file://$secret_file" \
      --region "$AWS_REGION" >/dev/null
  else
    secret_file="$(new_secret_file)"
    tmp_files+=("$secret_file")
    arn="$(aws secretsmanager create-secret \
      --name "$name" \
      --description "$description" \
      --secret-string "file://$secret_file" \
      --region "$AWS_REGION" \
      --tags Key=Project,Value=CloudStart Key=Environment,Value=dev Key=Component,Value=database-credentials \
      --query ARN \
      --output text)"
  fi

  case "$arn" in
    arn:*:secretsmanager:"$AWS_REGION":????????????:secret:*) ;;
    *)
      echo "AWS returned an unexpected Secrets Manager ARN for $name." >&2
      exit 1
      ;;
  esac

  rm -f "$current_file" "$error_file"
  printf '%s\n' "$arn"
}

runtime_arn="$(ensure_password_secret \
  "cloudstart-dev/database/runtime" \
  "CloudStart development PostgreSQL DML-only runtime login password")"

migrator_arn="$(ensure_password_secret \
  "cloudstart-dev/database/migrator" \
  "CloudStart development PostgreSQL Alembic migration login password")"

arn_tmp="$(mktemp "$SECRET_DIR/db-secret-arns.XXXXXX")"
tmp_files+=("$arn_tmp")
printf 'DB_RUNTIME_SECRET_ARN=%q\n' "$runtime_arn" >"$arn_tmp"
printf 'DB_MIGRATOR_SECRET_ARN=%q\n' "$migrator_arn" >>"$arn_tmp"
chmod 600 "$arn_tmp"
mv "$arn_tmp" "$ARN_ENV_FILE"

echo "Database credential secret containers are ready; password values were not displayed." >&2
echo "Runtime secret ARN: $runtime_arn" >&2
echo "Migrator secret ARN: $migrator_arn" >&2
