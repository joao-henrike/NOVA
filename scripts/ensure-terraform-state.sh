#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${AWS_REGION:?AWS_REGION is required}"
: "${EXPECTED_AWS_ACCOUNT_ID:?EXPECTED_AWS_ACCOUNT_ID is required}"
: "${TF_STATE_BUCKET:?TF_STATE_BUCKET is required}"

VERIFY_ONLY=false
case "${1:-}" in
  "") ;;
  --verify-only) VERIFY_ONLY=true ;;
  *) echo "Usage: $0 [--verify-only]" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOTSTRAP_DATA_DIR="$ROOT_DIR/.deploy/terraform-bootstrap-data"

command -v aws >/dev/null 2>&1 || {
  echo "AWS CLI is required to prepare Terraform remote state." >&2
  exit 1
}
command -v terraform >/dev/null 2>&1 || {
  echo "Terraform is required to prepare Terraform remote state." >&2
  exit 1
}

actual_account="$(aws sts get-caller-identity --query Account --output text)"
if [ "$actual_account" != "$EXPECTED_AWS_ACCOUNT_ID" ]; then
  echo "AWS account mismatch: expected $EXPECTED_AWS_ACCOUNT_ID, got $actual_account." >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/.deploy" "$BOOTSTRAP_DATA_DIR"
chmod 700 "$ROOT_DIR/.deploy"

error_file="$(mktemp "$ROOT_DIR/.deploy/state-bucket-error.XXXXXX")"
trap 'rm -f "$error_file"' EXIT

if bucket_region="$(aws s3api get-bucket-location \
  --bucket "$TF_STATE_BUCKET" \
  --expected-bucket-owner "$EXPECTED_AWS_ACCOUNT_ID" \
  --region "$AWS_REGION" \
  --query LocationConstraint \
  --output text 2>"$error_file")"; then
  case "$bucket_region" in
    None|null|"") bucket_region="us-east-1" ;;
  esac
  if [ "$bucket_region" != "$AWS_REGION" ]; then
    echo "Terraform state bucket $TF_STATE_BUCKET is in $bucket_region, not $AWS_REGION." >&2
    exit 1
  fi
  echo "Terraform state bucket is ready: $TF_STATE_BUCKET ($bucket_region)."
  exit 0
fi

if ! grep -Eq 'NoSuchBucket|404|Not Found' "$error_file"; then
  cat "$error_file" >&2
  echo "Could not verify ownership/access to Terraform state bucket $TF_STATE_BUCKET; refusing to create it." >&2
  exit 1
fi

if [ "$VERIFY_ONLY" = true ]; then
  echo "Terraform state bucket $TF_STATE_BUCKET is missing; verify-only mode will not create AWS resources." >&2
  exit 1
fi

echo "Terraform state bucket is missing; creating the protected bootstrap resources."

# Never let a changed bucket name replace a bucket recorded in the local bootstrap state.
BOOTSTRAP_STATE_FILE="$ROOT_DIR/bootstrap/terraform.tfstate"
if [ -s "$BOOTSTRAP_STATE_FILE" ]; then
  tracked_bucket="$(python3 - "$BOOTSTRAP_STATE_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)

matches = [
    resource
    for resource in state.get("resources", [])
    if resource.get("mode") == "managed"
    and resource.get("type") == "aws_s3_bucket"
    and resource.get("name") == "terraform_state"
]
if len(matches) != 1:
    raise SystemExit("Bootstrap state does not contain exactly one Terraform state bucket; refusing automatic changes.")

instances = matches[0].get("instances", [])
bucket = instances[0].get("attributes", {}).get("bucket") if instances else None
if not bucket:
    raise SystemExit("Could not read the state bucket name from bootstrap state; refusing automatic changes.")

print(bucket)
PY
  )"
  if [ "$tracked_bucket" != "$TF_STATE_BUCKET" ]; then
    echo "Bootstrap state tracks bucket $tracked_bucket, but TF_STATE_BUCKET is $TF_STATE_BUCKET." >&2
    echo "Refusing to replace or delete the previously tracked state bucket automatically." >&2
    exit 1
  fi
fi

export TF_DATA_DIR="$BOOTSTRAP_DATA_DIR"
terraform -chdir="$ROOT_DIR/bootstrap" init -backend=false -input=false -no-color

# The root backend uses S3 lockfiles. Import an existing compatibility table so
# a lost local bootstrap state does not make Terraform try to create it twice.
lock_table_name="cloudstart-terraform-lock"
lock_error="$(mktemp "$ROOT_DIR/.deploy/state-lock-table-error.XXXXXX")"
if aws dynamodb describe-table \
  --table-name "$lock_table_name" \
  --region "$AWS_REGION" >/dev/null 2>"$lock_error"; then
  if ! terraform -chdir="$ROOT_DIR/bootstrap" state show aws_dynamodb_table.terraform_lock >/dev/null 2>&1; then
    terraform -chdir="$ROOT_DIR/bootstrap" import \
      -input=false \
      -no-color \
      -var="aws_region=$AWS_REGION" \
      -var="state_bucket_name=$TF_STATE_BUCKET" \
      aws_dynamodb_table.terraform_lock "$lock_table_name"
  fi
elif ! grep -q "ResourceNotFoundException" "$lock_error"; then
  cat "$lock_error" >&2
  rm -f "$lock_error"
  echo "Could not verify the Terraform lock table; refusing automatic bootstrap." >&2
  exit 1
fi
rm -f "$lock_error"

terraform -chdir="$ROOT_DIR/bootstrap" apply \
  -input=false \
  -auto-approve \
  -no-color \
  -var="aws_region=$AWS_REGION" \
  -var="state_bucket_name=$TF_STATE_BUCKET"

bucket_region="$(aws s3api get-bucket-location \
  --bucket "$TF_STATE_BUCKET" \
  --expected-bucket-owner "$EXPECTED_AWS_ACCOUNT_ID" \
  --region "$AWS_REGION" \
  --query LocationConstraint \
  --output text)"
case "$bucket_region" in
  None|null|"") bucket_region="us-east-1" ;;
esac
if [ "$bucket_region" != "$AWS_REGION" ]; then
  echo "Created state bucket in unexpected region $bucket_region." >&2
  exit 1
fi

echo "Terraform state bucket bootstrap completed: $TF_STATE_BUCKET ($bucket_region)."
