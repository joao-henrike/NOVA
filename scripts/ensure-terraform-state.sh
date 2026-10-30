#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${AWS_REGION:?AWS_REGION is required}"
: "${EXPECTED_AWS_ACCOUNT_ID:?EXPECTED_AWS_ACCOUNT_ID is required}"
: "${TF_STATE_BUCKET:?TF_STATE_BUCKET is required}"

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

echo "Terraform state bucket is missing; creating the protected bootstrap resources."
export TF_DATA_DIR="$BOOTSTRAP_DATA_DIR"
terraform -chdir="$ROOT_DIR/bootstrap" init -backend=false -input=false -no-color
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
