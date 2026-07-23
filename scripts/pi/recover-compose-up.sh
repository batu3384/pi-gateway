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

# SSD yokken asla full stack — kirik symlink + recreate firtinasi
if needs_ssd_storage && ! mountpoint -q /mnt/ssd 2>/dev/null; then
  if storage_degraded || dns_degraded_on_ssd_loss; then
    COMPOSE_RECOVER_MODE=core-dns
  else
    echo "[recover-compose] HATA: SSD yok ve DNS degraded kapali — compose atlandi" >&2
    exit 1
  fi
fi

compose_up() {
  if [[ "${COMPOSE_RECOVER_MODE:-}" == "core-dns" ]]; then
    echo "[recover-compose] mode=core-dns (unbound adguard homepage caddy)" >&2
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

# Son care: force-recreate — core-dns'de sadece DNS seti (full stack degil)
echo "[recover-compose] WARN: ikinci deneme basarisiz — force-recreate" >&2
if [[ "${COMPOSE_RECOVER_MODE:-}" == "core-dns" ]]; then
  docker compose --env-file ../.env --profile caddy up -d --force-recreate --remove-orphans \
    unbound adguard homepage caddy
else
  compose_up --force-recreate --remove-orphans
fi
mark_stack_recover_cooldown
