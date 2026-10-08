#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/.tools"
BIN_DIR="$TOOLS_DIR/bin"
VENV_DIR="$ROOT_DIR/.venv"
DOCKER_CONFIG_DIR="$HOME/.docker"
DOCKER_CLI_PLUGINS_DIR="$DOCKER_CONFIG_DIR/cli-plugins"

TERRAFORM_VERSION="1.16.4"
TFLINT_VERSION="0.64.0"
COMPOSE_VERSION="5.6.0"
CHECKOV_VERSION="3.3.8"
PIP_AUDIT_VERSION="2.10.1"

mkdir -p "$BIN_DIR" "$DOCKER_CLI_PLUGINS_DIR"

say() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

has() {
  command -v "$1" >/dev/null 2>&1
}

install_terraform() {
  if "$BIN_DIR/terraform" version 2>/dev/null | grep -q "Terraform v$TERRAFORM_VERSION"; then
    return
  fi

  local archive="$TOOLS_DIR/terraform.zip"
  local url="https://releases.hashicorp.com/terraform/$TERRAFORM_VERSION/terraform_$TERRAFORM_VERSION""_linux_amd64.zip"

  say "Downloading Terraform $TERRAFORM_VERSION"
  curl -fsSL "$url" -o "$archive"
  unzip -qo "$archive" -d "$BIN_DIR"
  rm -f "$archive"
  "$BIN_DIR/terraform" version
}

install_tflint() {
  if "$BIN_DIR/tflint" --version 2>/dev/null | grep -q "TFLint version $TFLINT_VERSION"; then
    return
  fi

  local archive="$TOOLS_DIR/tflint.zip"
  local url="https://github.com/terraform-linters/tflint/releases/download/v$TFLINT_VERSION/tflint_linux_amd64.zip"

  say "Downloading TFLint $TFLINT_VERSION"
  curl -fsSL "$url" -o "$archive"
  unzip -qo "$archive" -d "$BIN_DIR"
  rm -f "$archive"
  "$BIN_DIR/tflint" --version
}

install_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose version
    return
  fi

  local arch
  case "$(uname -m)" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) fail "Unsupported CPU architecture for Docker Compose: $(uname -m)" ;;
  esac

  local plugin="$DOCKER_CLI_PLUGINS_DIR/docker-compose"
  local url="https://github.com/docker/compose/releases/download/v$COMPOSE_VERSION/docker-compose-linux-$arch"

  say "Downloading Docker Compose $COMPOSE_VERSION"
  curl -fsSL "$url" -o "$plugin"
  chmod +x "$plugin"
  docker compose version
}

install_aws_cli() {
  has aws && return
  [ -x "$BIN_DIR/aws" ] && return

  local arch
  case "$(uname -m)" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) fail "Unsupported CPU architecture: $(uname -m)" ;;
  esac

  local archive="$TOOLS_DIR/awscliv2.zip"
  local source_dir="$TOOLS_DIR/aws"

  say "Downloading AWS CLI v2"
  rm -rf "$source_dir"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$arch.zip" -o "$archive"
  unzip -qo "$archive" -d "$TOOLS_DIR"
  "$source_dir/install" -i "$TOOLS_DIR/aws-cli" -b "$BIN_DIR/aws"
  rm -rf "$source_dir" "$archive"
  "$BIN_DIR/aws" --version
}

check_python() {
  has python3 || fail "Python 3.12+ is required."

  python3 - <<'PY'
import sys
required = (3, 12)
if sys.version_info < required:
    raise SystemExit(
        "Python 3.12+ is required; found %s.%s"
        % (sys.version_info.major, sys.version_info.minor)
    )
PY
}

check_docker() {
  has docker || fail "Docker is required. AWS CloudShell provides Docker."
  docker info >/dev/null 2>&1 || fail "Docker daemon is unavailable."
}

setup_python() {
  say "Creating Python virtual environment"
  if [ ! -x "$VENV_DIR/bin/python" ]; then
    python3 -m venv "$VENV_DIR"
  fi

  "$VENV_DIR/bin/python" -m pip install --upgrade pip
  "$VENV_DIR/bin/pip" install     -r "$ROOT_DIR/apps/backend/requirements.txt"     -r "$ROOT_DIR/apps/backend/requirements-dev.txt"     "checkov==$CHECKOV_VERSION"     "pip-audit==$PIP_AUDIT_VERSION"
}

validate() {
  say "Validating repository"

  "$BIN_DIR/terraform" fmt -check -recursive
  "$BIN_DIR/terraform" init -backend=false -input=false -no-color
  "$BIN_DIR/terraform" validate -no-color

  "$BIN_DIR/terraform" -chdir="$ROOT_DIR/bootstrap" init -backend=false -input=false -no-color
  "$BIN_DIR/terraform" -chdir="$ROOT_DIR/bootstrap" validate -no-color

  "$VENV_DIR/bin/python" -m compileall -q     "$ROOT_DIR/apps/backend/app"     "$ROOT_DIR/apps/backend/tests"
}

main() {
  cd "$ROOT_DIR"

  say "CloudStart / NOVA local bootstrap"
  printf 'Repository: %s\n' "$ROOT_DIR"
  printf 'Terraform : %s\n' "$TERRAFORM_VERSION"
  printf 'TFLint    : %s\n' "$TFLINT_VERSION"
  printf 'Compose   : %s\n' "$COMPOSE_VERSION"

  has git || fail "Git is required."
  has curl || fail "curl is required."
  has unzip || fail "unzip is required."

  check_python
  check_docker
  install_terraform
  install_tflint
  install_compose
  install_aws_cli
  setup_python
  validate

  cat <<EOF

Bootstrap complete.

Run:
  export PATH="$BIN_DIR:\$PATH"
  source "$VENV_DIR/bin/activate"
  make doctor
  make up
EOF
}

main "$@"
