#!/usr/bin/env bash
# NOVA FinOps: AWS read-only collection and local-only dashboard
set -Eeuo pipefail
if [ "$#" -eq 0 ]; then
  echo "Usage: bash finops/run.sh collect|watch|report|serve|export|test [options]" >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="$1";shift
case "$ACTION" in
  collect|watch|report|serve|export)
    exec python3 "$ROOT/finops/finops.py" "$ACTION" "$@" ;;
  test) exec python3 -m unittest discover -s "$ROOT/finops/tests" -v ;;
  *) echo "Unknown action" >&2;exit 2 ;;
esac