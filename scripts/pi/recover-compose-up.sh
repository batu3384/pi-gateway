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

dns_fallback() {
  [[ -x "$SCRIPT_DIR/dns-host-fallback.sh" ]] || return 0
  bash "$SCRIPT_DIR/dns-host-fallback.sh" "$@" || true
}

# --force sonrası beklenmedik exit :53'ü boş bırakmasın (USB/hotplug).
_dns_force_stopped=0
_restore_dns_fallback() {
  [[ "${_dns_force_stopped}" == "1" ]] || return 0
  _dns_force_stopped=0
  echo "[recover-compose] EXIT trap — host DNS fallback" >&2
  dns_fallback start
}
trap '_restore_dns_fallback' EXIT

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
    dns_fallback start
    exit 1
  fi
fi

if ! timeout 8 /usr/bin/docker info >/dev/null 2>&1; then
  echo "[recover-compose] HATA: docker CLI yok — fallback koru, compose yok" >&2
  dns_fallback start
  exit 1
fi

_agh_rewrite_ok() {
  local _ip="${PI_STATIC_IP:-127.0.0.1}"
  local _dom="${LAN_DOMAIN:-home}"
  timeout 2 dig +time=1 +tries=1 +short @"$_ip" "gateway.${_dom}" A 2>/dev/null \
    | grep -qx "$_ip"
}

_compose_up_svcs() {
  local t="${COMPOSE_UP_TIMEOUT:-90}"
  if [[ "${COMPOSE_RECOVER_MODE:-}" == "core-dns" ]]; then
    timeout "$t" docker compose --env-file ../.env --profile caddy up -d "$@"
  else
    timeout "$t" docker compose --env-file ../.env "${profiles[@]}" up -d "$@"
  fi
}

# :53'ü compose boyunca boş bırakma — adguard host-network bind edene kadar fallback.
compose_up() {
  local -a core_svc=(unbound adguard)
  local -a pre
  local s
  if [[ "${ENABLE_CADDY:-true}" == "true" ]]; then
    core_svc+=(homepage caddy)
  fi
  if [[ "${COMPOSE_RECOVER_MODE:-}" == "core-dns" ]]; then
    echo "[recover-compose] mode=core-dns (${core_svc[*]})" >&2
  fi
  if _agh_rewrite_ok; then
    dns_fallback ensure
    if [[ "${COMPOSE_RECOVER_MODE:-}" == "core-dns" ]]; then
      _compose_up_svcs "${core_svc[@]}"
    else
      _compose_up_svcs
    fi
    return
  fi
  dns_fallback start
  if [[ "${COMPOSE_RECOVER_MODE:-}" == "core-dns" ]]; then
    pre=()
    for s in "${core_svc[@]}"; do
      [[ "$s" != adguard ]] && pre+=("$s")
    done
  else
    mapfile -t pre < <(docker compose --env-file ../.env "${profiles[@]}" config --services 2>/dev/null | grep -vx adguard || true)
  fi
  if ((${#pre[@]} == 0)); then
    echo "[recover-compose] WARN adguard-haric servis yok — :53 fallback" >&2
    return 1
  fi
  _compose_up_svcs "${pre[@]}" || return $?
  dns_fallback stop --force
  _dns_force_stopped=1
  _compose_up_svcs adguard
}

_wait_agh_rewrite() {
  local _ip="${PI_STATIC_IP:-127.0.0.1}"
  local _dom="${LAN_DOMAIN:-home}"
  local _i
  for _i in $(seq 1 "${AGH_REWRITE_WAIT_SEC:-60}"); do
    if timeout 2 dig +time=1 +tries=1 +short @"$_ip" "gateway.${_dom}" A 2>/dev/null \
      | grep -qx "$_ip"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

finish_ok() {
  # Önce :53 — dozzle/reap hung docker :53'ü boş bırakmasın.
  if _wait_agh_rewrite; then
    dns_fallback ensure
  else
    echo "[recover-compose] WARN AGH rewrite yok — host DNS fallback" >&2
    dns_fallback start
  fi
  _dns_force_stopped=0
  # shellcheck source=../lib/reap-dead-docker-scopes.sh
  source "$SCRIPT_DIR/../lib/reap-dead-docker-scopes.sh"
  reap_dead_docker_scopes || true
  if [[ "${COMPOSE_RECOVER_MODE:-}" != "core-dns" ]] \
    && [[ "${ENABLE_DOZZLE:-true}" == "true" ]] \
    && [[ ! -f "${REMOTE_DIR}/data/dozzle/users.yml" ]]; then
    echo "[recover-compose] dozzle users.yml eksik — setup-dozzle" >&2
    bash "$SCRIPT_DIR/setup-dozzle.sh" || true
    timeout "${COMPOSE_UP_TIMEOUT:-90}" docker compose --env-file ../.env --profile dozzle \
      up -d dozzle 2>/dev/null || true
  fi
  mark_stack_recover_cooldown
  exit 0
}
finish_fail() {
  echo "[recover-compose] HATA: compose recover basarisiz — cooldown yazilmiyor" >&2
  dns_fallback start
  _dns_force_stopped=0
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
if timeout "${COMPOSE_UP_TIMEOUT:-90}" docker compose --env-file ../.env "${up_profiles[@]}" \
  up -d --force-recreate --no-deps "${down_svc[@]}"; then
  finish_ok
fi
finish_fail
