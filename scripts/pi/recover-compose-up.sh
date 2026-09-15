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
if [[ -x "$SCRIPT_DIR/dns-host-fallback.sh" ]]; then
  bash "$SCRIPT_DIR/dns-host-fallback.sh" stop || true
fi
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
    docker compose --env-file ../.env "${profiles[@]}" up -d
  fi
}
finish_ok() {
  # shellcheck source=../lib/reap-dead-docker-scopes.sh
  source "$SCRIPT_DIR/../lib/reap-dead-docker-scopes.sh"
  reap_dead_docker_scopes || true
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
  if [[ -x "$SCRIPT_DIR/dns-host-fallback.sh" ]]; then
    bash "$SCRIPT_DIR/dns-host-fallback.sh" start || true
  fi
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
# Son care: YALNIZ calismayan servisler force-recreate (--no-deps). Tum stack'i
# recreate etmek sağlıklı DNS'i durdurur; 2026-09-13'te tek bozuk container'in
# rm hatasi bu yolla 4 saat DNS kesintisine dondu.
mapfile -t down_svc < <(comm -23 \
  <(docker compose --env-file ../.env "${profiles[@]}" config --services 2>/dev/null | sort) \
  <(docker compose --env-file ../.env "${profiles[@]}" ps --services --status running 2>/dev/null | sort))
up_profiles=("${profiles[@]}")
if [[ "${COMPOSE_RECOVER_MODE:-}" == "core-dns" ]]; then
  core_recreate=(unbound adguard)
  [[ "${ENABLE_CADDY:-true}" == "true" ]] && core_recreate+=(homepage caddy)
  mapfile -t down_svc < <(printf '%s\n' "${down_svc[@]}" \
    | grep -xF -f <(printf '%s\n' "${core_recreate[@]}") || true)
  up_profiles=(--profile caddy)
fi
if (( ${#down_svc[@]} == 0 )); then
  echo "[recover-compose] son care: calismayan servis yok" >&2
  finish_ok
fi
echo "[recover-compose] son care force-recreate: ${down_svc[*]}" >&2
if docker compose --env-file ../.env "${up_profiles[@]}" up -d --force-recreate --no-deps "${down_svc[@]}"; then
  finish_ok
fi
finish_fail
