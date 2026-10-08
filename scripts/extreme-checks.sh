#!/usr/bin/env bash
set -u

: "${LOG_DIR:=$RUNNER_TEMP/nova-extreme-logs}"
: "${RESULTS_FILE:=$RUNNER_TEMP/nova-extreme-results.tsv}"
: "${CHECK_TIMEOUT_SECONDS:=300}"

init_checks() {
  mkdir -p "$LOG_DIR"
  : > "$RESULTS_FILE"
}

run_check() {
  local name="$1"
  shift
  local log_file="$LOG_DIR/$name.log"
  echo
  echo "========== CHECK: $name =========="
  echo "COMMAND: $*"
  set +e
  timeout --kill-after=15s "${CHECK_TIMEOUT_SECONDS}s" "$@" 2>&1 | tee "$log_file"
  local rc=${PIPESTATUS[0]}
  set -e
  printf '%s	%s
' "$name" "$rc" >> "$RESULTS_FILE"
  if [ "$rc" -eq 0 ]; then
    echo "RESULT: PASS ($name)"
  else
    echo "RESULT: FAIL ($name) rc=$rc"
  fi
  return 0
}

record_external_result() {
  local name="$1"
  local rc="$2"
  printf '%s	%s
' "$name" "$rc" >> "$RESULTS_FILE"
}

finish_checks() {
  echo
  echo "========== DOMAIN VERDICT =========="
  if [ ! -s "$RESULTS_FILE" ]; then
    echo "No checks were recorded."
    return 1
  fi

  awk -F '\t' '{printf "%-45s %s\n", $1, ($2 == 0 ? "PASS" : "FAIL (" $2 ")")}' "$RESULTS_FILE"

  local failures
  failures="$(awk -F '\t' '$2 != 0 {count++} END {print count+0}' "$RESULTS_FILE")"
  echo
  echo "TOTAL FAILED CHECKS: $failures"
  return "$failures"
}
