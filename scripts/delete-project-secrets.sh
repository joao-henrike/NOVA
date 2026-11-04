#!/usr/bin/env bash
# Opt-in removal: only the three exact non-Terraform NOVA application secrets.
# Allow recovery for seven days instead of force-deleting credentials.
set -Eeuo pipefail
test -n "$AWS_REGION" && test -n "$EXPECTED_AWS_ACCOUNT_ID" || { echo "Missing AWS region/account" >&2; exit 1; }
account="$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")"
[[ "$account" == "$EXPECTED_AWS_ACCOUNT_ID" ]] || { echo "Wrong AWS account." >&2; exit 1; }

for name in cloudstart-dev/database/runtime cloudstart-dev/database/migrator cloudstart-dev/backend/authentication; do
  err="$(mktemp)"
  if metadata="$(aws secretsmanager describe-secret --secret-id "$name" \
    --region "$AWS_REGION" --output json 2>"$err")"; then
    rm -f "$err"
    if jq -e '.DeletedDate != null' <<< "$metadata" >/dev/null; then
      echo "ALREADY_SCHEDULED=$name"
    else
      aws secretsmanager delete-secret --secret-id "$name" \
        --recovery-window-in-days 7 --region "$AWS_REGION" >/dev/null
      echo "SCHEDULED_DELETION=$name (7-day recovery)"
    fi
  elif grep -q 'ResourceNotFoundException' "$err"; then
    rm -f "$err"
    echo "ABSENT_SECRET=$name"
  else
    cat "$err" >&2
    rm -f "$err"
    exit 1
  fi
done
