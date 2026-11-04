#!/usr/bin/env bash
set -euo pipefail

for attempt in $(seq 1 30); do
  if docker compose exec -T postgres pg_isready       -U cloudstart_admin       -d cloudstart >/dev/null 2>&1; then
    echo "PostgreSQL is ready."
    exit 0
  fi

  echo "Waiting for PostgreSQL... attempt $attempt/30"
  sleep 2
done

echo "PostgreSQL did not become ready." >&2
docker compose logs postgres >&2 || true
exit 1
