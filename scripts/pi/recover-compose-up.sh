#!/usr/bin/env bash
# recover-readonly-root icinden batu kullanicisi ile docker compose up
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && set -a && source "$REMOTE_DIR/.env" && set +a
# shellcheck source=../lib/compose-profiles.sh
source "$SCRIPT_DIR/../lib/compose-profiles.sh"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

cd "$REMOTE_DIR/compose"
mapfile -t profiles < <(compose_profiles)

compose_up() {
  if [[ "${COMPOSE_RECOVER_MODE:-}" == "core-dns" ]]; then
    docker compose --env-file ../.env --profile caddy up -d unbound adguard homepage caddy
  else
    docker compose --env-file ../.env "${profiles[@]}" up -d "$@"
  fi
}

finish_ok() {
  mark_stack_recover_cooldown
  exit 0
}

if compose_up; then
  finish_ok
fi

# Soft: stale ag temizle, recreate yok
echo "[recover-compose] WARN: compose up basarisiz — network prune + up" >&2
docker network prune -f >/dev/null 2>&1 || true
if compose_up; then
  finish_ok
fi

# Son care: force-recreate (down yok)
echo "[recover-compose] WARN: ikinci deneme basarisiz — force-recreate" >&2
compose_up --force-recreate --remove-orphans
mark_stack_recover_cooldown
