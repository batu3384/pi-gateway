#!/usr/bin/env bash
# recover-readonly-root icinden PI_USER ile docker compose up
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

# SSD yok/stale: asla full app stack (ephemeral SD data clobber riski)
ssd_ok=0
if declare -F ssd_mount_healthy >/dev/null 2>&1; then
  ssd_mount_healthy && ssd_ok=1
elif mountpoint -q /mnt/ssd 2>/dev/null; then
  ssd_ok=1
fi
if needs_ssd_storage && [[ "$ssd_ok" -ne 1 ]]; then
  if storage_degraded || dns_degraded_on_ssd_loss; then
    COMPOSE_RECOVER_MODE=core-dns
  else
    echo "[recover-compose] HATA: SSD yok ve DNS degraded kapali — compose atlandi" >&2
    exit 1
  fi
fi

compose_up() {
    if [[ "${COMPOSE_RECOVER_MODE:-}" == "core-dns" ]]; then
    echo "[recover-compose] mode=core-dns (unbound+adguard; homepage/caddy best-effort)" >&2
    docker compose --env-file ../.env --profile caddy up -d unbound adguard homepage caddy
  else
    docker compose --env-file ../.env "${profiles[@]}" up -d "$@"
  fi
}

finish_ok() {
  if [[ "${ENABLE_DOZZLE:-true}" == "true" ]] \
    && [[ ! -f "${REMOTE_DIR}/data/dozzle/users.yml" ]]; then
    echo "[recover-compose] dozzle users.yml eksik — setup-dozzle" >&2
    bash "$SCRIPT_DIR/setup-dozzle.sh" || true
    docker compose --env-file ../.env --profile dozzle up -d dozzle 2>/dev/null || true
  fi
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
finish_ok
