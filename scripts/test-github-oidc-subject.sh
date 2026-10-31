#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

grep -Fq 'repo:joao-henrike@${var.github_owner_id}/NOVA@${var.github_repository_id}:environment:${var.github_environment}' bootstrap/github-oidc/main.tf
grep -Fq 'default     = "joao-henrike/NOVA"' bootstrap/github-oidc/variables.tf
grep -Fq 'default     = "133373332"' bootstrap/github-oidc/variables.tf
grep -Fq 'default     = "1393500090"' bootstrap/github-oidc/variables.tf
grep -Fq 'token.actions.githubusercontent.com:aud' bootstrap/github-oidc/main.tf
grep -Fq 'values   = ["sts.amazonaws.com"]' bootstrap/github-oidc/main.tf
grep -B1 -A1 'variable = "ecs:task-cpu"' bootstrap/github-oidc/main.tf | grep -Fq 'test     = "NumericEquals"'
grep -B1 -A1 'variable = "ecs:task-memory"' bootstrap/github-oidc/main.tf | grep -Fq 'test     = "NumericEquals"'

if grep -R -Fq 'repo:joao-henrique@' bootstrap/github-oidc docs; then
  echo "Invalid GitHub OIDC owner login found in trust documentation or configuration." >&2
  exit 1
fi

echo "GitHub OIDC immutable subject contract passed."
