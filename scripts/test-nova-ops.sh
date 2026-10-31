#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/repo/scripts" "$TEMP_DIR/repo/config" "$TEMP_DIR/mock-bin"
cp "$ROOT_DIR/scripts/nova-ops.sh" "$TEMP_DIR/repo/scripts/nova-ops.sh"
cp "$ROOT_DIR/config/dev.tfvars" "$TEMP_DIR/repo/config/dev.tfvars"
cp "$ROOT_DIR/config/dev.env" "$TEMP_DIR/repo/config/dev.env"

cat > "$TEMP_DIR/mock-bin/aws" <<'MOCK_AWS'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$NOVA_OPS_TEST_LOG"
case "$*" in
  *"sts get-caller-identity"*) printf '760396521507\n' ;;
  *"application-autoscaling register-scalable-target"*) printf '{}\n' ;;
  *"ecs update-service"*) printf '{}\n' ;;
  *"ecs describe-services"*) printf '0\n' ;;
  *"rds describe-db-instances"*) printf 'available\n' ;;
  *"rds stop-db-instance"*) printf '{}\n' ;;
  *) printf 'Unexpected mocked AWS command: %s\n' "$*" >&2; exit 90 ;;
esac
MOCK_AWS
chmod +x "$TEMP_DIR/mock-bin/aws"

export PATH="$TEMP_DIR/mock-bin:$PATH"
export NOVA_OPS_TEST_LOG="$TEMP_DIR/aws-calls.log"

bash "$TEMP_DIR/repo/scripts/nova-ops.sh" help >/dev/null
bash "$TEMP_DIR/repo/scripts/nova-ops.sh" scale frontend 1 >/dev/null
grep -q 'application-autoscaling register-scalable-target' "$NOVA_OPS_TEST_LOG"
grep -q -- '--min-capacity 1' "$NOVA_OPS_TEST_LOG"
grep -q 'ecs update-service' "$NOVA_OPS_TEST_LOG"
grep -q -- '--desired-count 1' "$NOVA_OPS_TEST_LOG"

if bash "$TEMP_DIR/repo/scripts/nova-ops.sh" scale frontend 7 >/dev/null 2>&1; then
  printf 'FAIL: scale exceeded the Terraform-configured maximum.\n' >&2
  exit 1
fi

if NOVA_EXPECTED_ACCOUNT_ID=999999999999 bash "$TEMP_DIR/repo/scripts/nova-ops.sh" scale frontend 1 >/dev/null 2>&1; then
  printf 'FAIL: wrong AWS account was accepted.\n' >&2
  exit 1
fi
if grep -q 'ecs update-service' "$NOVA_OPS_TEST_LOG" && [[ "$(grep -c 'ecs update-service' "$NOVA_OPS_TEST_LOG")" -ne 1 ]]; then
  printf 'FAIL: a service mutation was attempted after account mismatch.\n' >&2
  exit 1
fi

if bash "$TEMP_DIR/repo/scripts/nova-ops.sh" scale monitoring 2 >/dev/null 2>&1; then
  printf 'FAIL: monitoring accepted more than one replica.\n' >&2
  exit 1
fi

if bash "$TEMP_DIR/repo/scripts/nova-ops.sh" logs unknown >/dev/null 2>&1; then
  printf 'FAIL: an unknown log group was accepted.\n' >&2
  exit 1
fi

if bash "$TEMP_DIR/repo/scripts/nova-ops.sh" db stop application >/dev/null 2>&1; then
  printf 'FAIL: RDS stop ran without an interactive exact confirmation.\n' >&2
  exit 1
fi
if grep -q 'rds stop-db-instance' "$NOVA_OPS_TEST_LOG"; then
  printf 'FAIL: RDS stop API was called without confirmation.\n' >&2
  exit 1
fi

printf 'NOVA Ops tests passed.\n'
