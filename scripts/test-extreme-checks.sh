#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export RUNNER_TEMP="$TEST_DIR"
export LOG_DIR="$TEST_DIR/logs"
export RESULTS_FILE="$TEST_DIR/results.tsv"
source "$ROOT_DIR/scripts/extreme-checks.sh"

init_checks
record_external_result local_check 0
if ! finish_checks; then
  echo "A complete, passing result set must succeed." >&2
  exit 1
fi

: > "$RESULTS_FILE"
record_skipped_check missing_aws_role
if finish_checks; then
  echo "A skipped check must block complete validation." >&2
  exit 1
fi

: > "$RESULTS_FILE"
record_external_result failed_check 2
if finish_checks; then
  echo "A failed check must block complete validation." >&2
  exit 1
fi

echo "Extreme validation verdict contract passed."
