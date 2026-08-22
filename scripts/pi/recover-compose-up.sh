#!/usr/bin/env bash
# recover-readonly-root icinden PI_USER ile docker compose up
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
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
    local -a core_svc=(unbound adguard)
    if [[ "${ENABLE_CADDY:-true}" == "true" ]]; then
      core_svc+=(homepage caddy)
    fi
    echo "[recover-compose] mode=core-dns (${core_svc[*]})" >&2
    docker compose --env-file ../.env --profile caddy up -d "${core_svc[@]}"
  else
    docker compose --env-file ../.env "${profiles[@]}" up -d "$@"
  fi
}
finish_ok() {
  if [[ "${COMPOSE_RECOVER_MODE:-}" != "core-dns" ]] \
    && [[ "${ENABLE_DOZZLE:-true}" == "true" ]] \
    && [[ ! -f "${REMOTE_DIR}/data/dozzle/users.yml" ]]; then
    echo "[recover-compose] dozzle users.yml eksik — setup-dozzle" >&2
    bash "$SCRIPT_DIR/setup-dozzle.sh" || true
    docker compose --env-file ../.env --profile dozzle up -d dozzle 2>/dev/null || true
  fi
  mark_stack_recover_cooldown
  exit 0
}
finish_fail() {
  echo "[recover-compose] HATA: compose recover basarisiz — cooldown yazilmiyor" >&2
  exit 1
}
if compose_up; then
  finish_ok
fi
echo "[recover-compose] WARN: compose up basarisiz — network prune + up" >&2
docker network prune -f >/dev/null 2>&1 || true
if compose_up; then
  finish_ok
fi
echo "[recover-compose] WARN: ikinci deneme basarisiz — son care" >&2
# Son care: force-recreate — core-dns'de sadece DNS seti (full stack degil)
if [[ "${COMPOSE_RECOVER_MODE:-}" == "core-dns" ]]; then
  core_recreate=(unbound adguard)
  [[ "${ENABLE_CADDY:-true}" == "true" ]] && core_recreate+=(homepage caddy)
  if docker compose --env-file ../.env --profile caddy up -d --force-recreate --remove-orphans \
    "${core_recreate[@]}"; then
    finish_ok
  fi
else
  if compose_up --force-recreate --remove-orphans; then
    finish_ok
  fi
fi
finish_fail
