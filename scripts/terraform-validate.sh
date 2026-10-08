#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TERRAFORM="$ROOT_DIR/.tools/bin/terraform"
RUN_ID="nova-tf-validate-$$"
WORK_ROOT="${TMPDIR:-/tmp}/$RUN_ID"
PROVIDER_CACHE="$WORK_ROOT/provider-cache"
TF_CLI_CONFIG="$WORK_ROOT/terraformrc"

cleanup() {
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

mkdir -p "$WORK_ROOT/root" "$WORK_ROOT/bootstrap" "$PROVIDER_CACHE"

copy_tf_files() {
  local src="$1"
  local dst="$2"

  find "$src" -maxdepth 1 -type f -name '*.tf' -exec cp -p {} "$dst/" \;
  [ ! -f "$src/.terraform.lock.hcl" ] || cp -p "$src/.terraform.lock.hcl" "$dst/"
}

copy_tf_files "$ROOT_DIR" "$WORK_ROOT/root"
copy_tf_files "$ROOT_DIR/bootstrap" "$WORK_ROOT/bootstrap"

cat > "$TF_CLI_CONFIG" <<EOF
plugin_cache_dir = "$PROVIDER_CACHE"
EOF

export TF_CLI_CONFIG_FILE="$TF_CLI_CONFIG"

printf '%s\n' "Terraform validation workspace: $WORK_ROOT"
printf '%s\n' "Provider cache: $PROVIDER_CACHE"

"$TERRAFORM" -chdir="$WORK_ROOT/root" init   -backend=false   -input=false   -no-color

"$TERRAFORM" -chdir="$WORK_ROOT/root" validate -no-color

"$TERRAFORM" -chdir="$WORK_ROOT/bootstrap" init   -backend=false   -input=false   -no-color

"$TERRAFORM" -chdir="$WORK_ROOT/bootstrap" validate -no-color

printf '%s\n' "Terraform root and bootstrap validation passed."
