#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${AWS_REGION:?AWS_REGION is required}"
: "${EXPECTED_AWS_ACCOUNT_ID:?EXPECTED_AWS_ACCOUNT_ID is required}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SECRET_DIR="$ROOT_DIR/.deploy"
SECRET_NAME="${BACKEND_AUTH_SECRET_NAME:-cloudstart-dev/backend/authentication}"
ARN_ENV_FILE="$SECRET_DIR/backend-auth-secret-arn.env"

command -v aws >/dev/null 2>&1 || {
  echo "AWS CLI is required." >&2
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

current_file="$(mktemp "$SECRET_DIR/backend-auth-current.XXXXXX.json")"
secret_file="$(mktemp "$SECRET_DIR/backend-auth-secret.XXXXXX.json")"
error_file="$(mktemp "$SECRET_DIR/backend-auth-error.XXXXXX")"
describe_error="$(mktemp "$SECRET_DIR/backend-auth-describe.XXXXXX")"
arn_tmp="$(mktemp "$SECRET_DIR/backend-auth-arn.XXXXXX")"
cleanup() {
  rm -f "$current_file" "$secret_file" "$error_file" "$describe_error" "$arn_tmp"
}
trap cleanup EXIT
chmod 600 "$current_file" "$secret_file" "$error_file" "$describe_error" "$arn_tmp"

secret_arn=""
updated=false

if secret_arn="$(aws secretsmanager describe-secret \
  --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" \
  --query ARN \
  --output text 2>"$describe_error")"; then

  if ! aws secretsmanager get-secret-value \
    --secret-id "$secret_arn" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text >"$current_file" 2>"$error_file"; then
    cat "$error_file" >&2
    echo "Could not read existing backend authentication secret $SECRET_NAME." >&2
    exit 1
  fi

  updated="$(python3 - "$current_file" "$secret_file" <<'PY'
import json
import os
import sys

source, destination = sys.argv[1:3]
required = (
    "AUTH_JWT_SECRET_KEY",
    "GOOGLE_CLIENT_ID",
    "GOOGLE_CLIENT_SECRET",
    "GOOGLE_REDIRECT_URI",
    "APPLE_CLIENT_ID",
    "APPLE_TEAM_ID",
    "APPLE_KEY_ID",
    "APPLE_PRIVATE_KEY",
    "APPLE_REDIRECT_URI",
)
oauth = required[1:]

try:
    with open(source, encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"Existing backend authentication secret is not valid JSON: {exc}")

if not isinstance(payload, dict):
    raise SystemExit("Existing backend authentication secret must be a JSON object.")

missing = [key for key in required if key not in payload]
if missing:
    raise SystemExit(
        "Existing backend authentication secret is missing keys: " + ", ".join(missing)
    )

invalid = [key for key in required if not isinstance(payload.get(key), str)]
if invalid:
    raise SystemExit(
        "Existing backend authentication secret has non-string values: " + ", ".join(invalid)
    )

if len(payload["AUTH_JWT_SECRET_KEY"]) < 32:
    raise SystemExit("Existing AUTH_JWT_SECRET_KEY must contain at least 32 characters.")

changed = False
for key in oauth:
    supplied = os.environ.get(key, "")
    if supplied and payload.get(key) != supplied:
        payload[key] = supplied
        changed = True

google = [payload[key] for key in (
    "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GOOGLE_REDIRECT_URI"
)]
apple = [payload[key] for key in (
    "APPLE_CLIENT_ID", "APPLE_TEAM_ID", "APPLE_KEY_ID",
    "APPLE_PRIVATE_KEY", "APPLE_REDIRECT_URI"
)]
if any(google) and not all(google):
    raise SystemExit(
        "Google OAuth requires GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET and GOOGLE_REDIRECT_URI."
    )
if any(apple) and not all(apple):
    raise SystemExit(
        "Apple OAuth requires APPLE_CLIENT_ID, APPLE_TEAM_ID, APPLE_KEY_ID, "
        "APPLE_PRIVATE_KEY and APPLE_REDIRECT_URI."
    )

with open(destination, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, separators=(",", ":"), ensure_ascii=False)
    handle.write("\n")

print("true" if changed else "false")
PY
  )"

  if [ "$updated" = "true" ]; then
    aws secretsmanager put-secret-value \
      --secret-id "$secret_arn" \
      --secret-string "file://$secret_file" \
      --region "$AWS_REGION" >/dev/null
  fi
else
  if ! grep -q "ResourceNotFoundException" "$describe_error"; then
    cat "$describe_error" >&2
    echo "Could not determine whether backend authentication secret $SECRET_NAME exists." >&2
    exit 1
  fi

  python3 - "$secret_file" <<'PY'
import json
import os
import secrets
import sys

keys = (
    "GOOGLE_CLIENT_ID",
    "GOOGLE_CLIENT_SECRET",
    "GOOGLE_REDIRECT_URI",
    "APPLE_CLIENT_ID",
    "APPLE_TEAM_ID",
    "APPLE_KEY_ID",
    "APPLE_PRIVATE_KEY",
    "APPLE_REDIRECT_URI",
)
payload = {"AUTH_JWT_SECRET_KEY": secrets.token_urlsafe(48)}
payload.update({key: os.environ.get(key, "") for key in keys})

google = [payload[key] for key in (
    "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GOOGLE_REDIRECT_URI"
)]
apple = [payload[key] for key in (
    "APPLE_CLIENT_ID", "APPLE_TEAM_ID", "APPLE_KEY_ID",
    "APPLE_PRIVATE_KEY", "APPLE_REDIRECT_URI"
)]
if any(google) and not all(google):
    raise SystemExit(
        "Google OAuth requires GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET and GOOGLE_REDIRECT_URI."
    )
if any(apple) and not all(apple):
    raise SystemExit(
        "Apple OAuth requires APPLE_CLIENT_ID, APPLE_TEAM_ID, APPLE_KEY_ID, "
        "APPLE_PRIVATE_KEY and APPLE_REDIRECT_URI."
    )

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, separators=(",", ":"), ensure_ascii=False)
    handle.write("\n")
PY

  secret_arn="$(aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "CloudStart development backend JWT and optional OAuth configuration" \
    --secret-string "file://$secret_file" \
    --region "$AWS_REGION" \
    --query ARN \
    --output text)"
  updated=true
fi

case "$secret_arn" in
  "arn:aws:secretsmanager:$AWS_REGION:$EXPECTED_AWS_ACCOUNT_ID:secret:"*) ;;
  *)
    echo "AWS returned an unexpected backend authentication secret ARN." >&2
    exit 1
    ;;
esac

printf 'BACKEND_AUTH_SECRET_ARN=%q\n' "$secret_arn" >"$arn_tmp"
printf 'BACKEND_AUTH_SECRET_UPDATED=%q\n' "$updated" >>"$arn_tmp"
chmod 600 "$arn_tmp"
mv "$arn_tmp" "$ARN_ENV_FILE"

echo "Backend authentication secret is ready; JWT material and provider credentials were not displayed."
echo "Backend authentication secret ARN: $secret_arn"
