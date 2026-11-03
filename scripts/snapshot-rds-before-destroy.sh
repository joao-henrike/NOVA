#!/usr/bin/env bash
# A snapshot failure blocks any Terraform destruction. Exact known dev RDS IDs.
set -Eeuo pipefail
test -n "$AWS_REGION" && test -n "$EXPECTED_AWS_ACCOUNT_ID" || { echo "Missing AWS region/account" >&2; exit 1; }
actual="$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")"
[[ "$actual" == "$EXPECTED_AWS_ACCOUNT_ID" ]] || { echo "Wrong account $actual" >&2; exit 1; }

for database in cloudstart-dev-db cloudstart-dev-monitoring-db; do
  error="$(mktemp)"
  if state="$(aws rds describe-db-instances --db-instance-identifier "$database" \
    --region "$AWS_REGION" --query 'DBInstances[0].DBInstanceStatus' --output text 2>"$error")"; then
    :
  elif grep -q 'DBInstanceNotFound' "$error"; then
    echo "ABSENT_DATABASE=$database"
    rm -f "$error"
    continue
  else
    cat "$error" >&2
    rm -f "$error"
    exit 1
  fi
  rm -f "$error"
  case "$state" in
    available) ;;
    stopped)
      echo "Starting $database for pre-destroy snapshot."
      aws rds start-db-instance --db-instance-identifier "$database" --region "$AWS_REGION" >/dev/null
      aws rds wait db-instance-available --db-instance-identifier "$database" --region "$AWS_REGION"
      ;;
    *) echo "RDS $database is $state: cannot take required snapshot." >&2; exit 1 ;;
  esac

  snapshot="$database-pre-destroy-$(date -u +%Y%m%d%H%M%S)"
  echo "Creating manual snapshot $snapshot"
  aws rds create-db-snapshot --db-instance-identifier "$database" \
    --db-snapshot-identifier "$snapshot" --region "$AWS_REGION" >/dev/null
  aws rds wait db-snapshot-available --db-snapshot-identifier "$snapshot" --region "$AWS_REGION"
  echo "PRESERVED_SNAPSHOT=$snapshot"
done
