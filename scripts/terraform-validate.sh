#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TERRAFORM="${TERRAFORM:-$ROOT_DIR/.tools/bin/terraform}"
RUN_ID="nova-tf-validate-$$"
WORK_ROOT="${TMPDIR:-/tmp}/$RUN_ID"
PROVIDER_CACHE="$WORK_ROOT/provider-cache"
TF_CLI_CONFIG="$WORK_ROOT/terraformrc"

cleanup() {
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

mkdir -p "$WORK_ROOT/root" "$WORK_ROOT/bootstrap" "$WORK_ROOT/bootstrap/github-oidc" "$PROVIDER_CACHE"

copy_tf_files() {
  local src="$1"
  local dst="$2"

  find "$src" -maxdepth 1 -type f -name '*.tf' -exec cp -p {} "$dst/" \;
  [ ! -f "$src/.terraform.lock.hcl" ] || cp -p "$src/.terraform.lock.hcl" "$dst/"
}

copy_tf_files "$ROOT_DIR" "$WORK_ROOT/root"
copy_tf_files "$ROOT_DIR/bootstrap" "$WORK_ROOT/bootstrap"
copy_tf_files "$ROOT_DIR/bootstrap/github-oidc" "$WORK_ROOT/bootstrap/github-oidc"

# Stage only source assets referenced by Terraform. The dashboard fileset is
# otherwise silently empty in the isolated validation workspace.
python3 - "$ROOT_DIR" "$WORK_ROOT/root" <<'PY'
import json
from pathlib import Path
import shutil
import sys

root, dest = map(Path, sys.argv[1:])
grafana = root / "monitoring/grafana"
manifest = json.loads((grafana / "manifest.json").read_text(encoding="utf-8"))
entries = manifest["dashboards"]
paths = [Path("monitoring/grafana") / d["path"] for d in entries]
expected = {p.as_posix() for p in paths}
actual = {
    p.relative_to(root).as_posix()
    for p in (grafana / "dashboards").rglob("*.json")
    if p.is_file()
}
if len(paths) != 30 or len(expected) != 30 or actual != expected:
    raise SystemExit("Missing, duplicate, or unexpected monitoring dashboard asset")
assets = [Path("monitoring/bootstrap.py"), Path("monitoring/collector.py"), *paths]
for relative in assets:
    source = root / relative
    if relative.is_absolute() or ".." in relative.parts or not source.is_file():
        raise SystemExit(f"Missing or invalid monitoring source: {relative}")
    if not source.resolve().is_relative_to(root.resolve()):
        raise SystemExit(f"Monitoring source outside checkout: {relative}")
    target = dest / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
print(f"Staged {len(assets)} monitoring source assets (30 dashboards)")
PY

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

"$TERRAFORM" -chdir="$WORK_ROOT/bootstrap/github-oidc" init -backend=false -input=false -no-color

"$TERRAFORM" -chdir="$WORK_ROOT/bootstrap/github-oidc" validate -no-color

printf '%s\n' "Terraform root, state bootstrap, and GitHub OIDC bootstrap validation passed."
