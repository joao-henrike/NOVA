#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_BIN="$ROOT_DIR/.tools/bin"
VENV_BIN="$ROOT_DIR/.venv/bin"

ok=0
failures=0

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'OK    %-18s %s\n' "$name" "$("$@" 2>&1 | head -n 1)"
    ok=$((ok + 1))
  else
    printf 'FAIL  %-18s\n' "$name"
    failures=$((failures + 1))
  fi
}

printf '%s\n' "CloudStart / NOVA environment doctor"
printf '%s\n' "Repository: $ROOT_DIR"
printf '%s\n\n' "Branch: $(git -C "$ROOT_DIR" branch --show-current)"

test "$(git -C "$ROOT_DIR" branch --show-current)" = "Joao"   && printf 'OK    %-18s Joao\n' "git-branch"   || { printf 'FAIL  %-18s expected Joao\n' "git-branch"; failures=$((failures + 1)); }

check "terraform" "$TOOLS_BIN/terraform" version
check "tflint" "$TOOLS_BIN/tflint" --version
check "python" "$VENV_BIN/python" --version
check "pytest" "$VENV_BIN/python" -m pytest --version
check "ruff" "$VENV_BIN/python" -m ruff --version
check "mypy" "$VENV_BIN/python" -m mypy --version
check "bandit" "$VENV_BIN/python" -m bandit --version
check "checkov" "$VENV_BIN/checkov" --version
check "pip-audit" "$VENV_BIN/pip-audit" --version
check "docker" docker --version
check "compose" docker compose version
check "aws" aws --version
check "curl" curl --version

printf '\n'
if [ "$failures" -eq 0 ]; then
  printf 'Doctor result: PASS (%s checks)\n' "$ok"
  exit 0
fi

printf 'Doctor result: FAIL (%s failures)\n' "$failures" >&2
exit 1
