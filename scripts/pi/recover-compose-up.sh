#!/usr/bin/env bash
# recover-readonly-root icinden batu kullanicisi ile docker compose up
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"
# shellcheck source=../lib/compose-profiles.sh
source "$SCRIPT_DIR/../lib/compose-profiles.sh"

cd "$REMOTE_DIR/compose"
mapfile -t profiles < <(compose_profiles)

compose_up() {
  docker compose --env-file ../.env "${profiles[@]}" up -d
}

if compose_up; then
  exit 0
fi

echo "[recover-compose] WARN: compose up basarisiz — ag onarimi deneniyor" >&2
docker network prune -f >/dev/null 2>&1 || true
docker compose --env-file ../.env "${profiles[@]}" down --remove-orphans >/dev/null 2>&1 || true
docker network prune -f >/dev/null 2>&1 || true
exec docker compose --env-file ../.env "${profiles[@]}" up -d --force-recreate
