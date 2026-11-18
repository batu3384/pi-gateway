#!/usr/bin/env bash
# CI: secret-free compose config check (fixture .env)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$ROOT/.github/ci.env.fixture"
TMP_ENV="$(mktemp)"
trap 'rm -f "$TMP_ENV"' EXIT

cp "$FIXTURE" "$TMP_ENV"

PROF=(--profile caddy --profile gatus --profile dozzle --profile netalert --profile crowdsec --profile monitoring)

if docker compose version >/dev/null 2>&1; then
  docker compose -f "$ROOT/compose/docker-compose.yml" --env-file "$TMP_ENV" "${PROF[@]}" config -q
elif command -v docker-compose >/dev/null 2>&1; then
  docker-compose -f "$ROOT/compose/docker-compose.yml" --env-file "$TMP_ENV" "${PROF[@]}" config -q
else
  echo "[ci-compose] HATA: docker compose yok" >&2
  exit 1
fi

echo "[ci-compose] OK"
