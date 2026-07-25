#!/usr/bin/env bash
# Stack sagligi ve kurtarma kilidi (health-check, watchdog, recover-ro)
set -euo pipefail

# recover-ro TimeoutStartSec (360) altinda kalmali; waiter biraz daha uzun bekler
STACK_RECOVER_WAIT_SEC="${STACK_RECOVER_WAIT_SEC:-330}"
STACK_LOCK_FILE="${STACK_LOCK_FILE:-/run/pi-gateway/stack-recover.lock}"
STORAGE_DEGRADED_FLAG="${STORAGE_DEGRADED_FLAG:-/run/pi-gateway/storage-degraded}"
STACK_RECOVER_COOLDOWN_SEC="${STACK_RECOVER_COOLDOWN_SEC:-180}"
STACK_RECOVER_COOLDOWN_DEGRADED_SEC="${STACK_RECOVER_COOLDOWN_DEGRADED_SEC:-900}"
STACK_RECOVER_COOLDOWN_FILE="${STACK_RECOVER_COOLDOWN_FILE:-/run/pi-gateway/stack-recover-cooldown}"
STACK_BOOT_GRACE_SEC="${STACK_BOOT_GRACE_SEC:-120}"
SSD_HOTPLUG_STATE_FILE="${SSD_HOTPLUG_STATE_FILE:-/var/lib/pi-gateway/ssd-hotplug-mounted}"
SSD_HOTPLUG_DEBOUNCE_SEC="${SSD_HOTPLUG_DEBOUNCE_SEC:-120}"
PI_GATEWAY_RUNTIME_DIR="${PI_GATEWAY_RUNTIME_DIR:-/run/pi-gateway}"

# /run/pi-gateway batu yazabilir olsun (root hotplug sonrasi stuck flag onleme)
ensure_runtime_dir() {
  local owner
  owner="$(pi_user_from_remote_dir "${REMOTE_DIR:-/home/${PI_USER:-batu}/pi-gateway}")"
  if [[ "$(id -u)" -eq 0 ]]; then
    mkdir -p "$PI_GATEWAY_RUNTIME_DIR"
    chown "${owner}:${owner}" "$PI_GATEWAY_RUNTIME_DIR" 2>/dev/null || true
    chmod 775 "$PI_GATEWAY_RUNTIME_DIR" 2>/dev/null || true
  else
    mkdir -p "$PI_GATEWAY_RUNTIME_DIR" 2>/dev/null \
      || sudo mkdir -p "$PI_GATEWAY_RUNTIME_DIR" 2>/dev/null || true
    sudo chown "${owner}:${owner}" "$PI_GATEWAY_RUNTIME_DIR" 2>/dev/null || true
    sudo chmod 775 "$PI_GATEWAY_RUNTIME_DIR" 2>/dev/null || true
  fi
}

runtime_rm() {
  local path="$1"
  rm -f "$path" 2>/dev/null && return 0
  if [[ "$(id -u)" -eq 0 ]]; then
    rm -f "$path" 2>/dev/null || return 1
  else
    sudo rm -f "$path" 2>/dev/null || return 1
  fi
}

runtime_write() {
  local path="$1" content="$2"
  ensure_runtime_dir
  if printf '%s\n' "$content" >"$path" 2>/dev/null; then
    return 0
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    printf '%s\n' "$content" >"$path"
  else
    printf '%s\n' "$content" | sudo tee "$path" >/dev/null
    local owner
    owner="$(pi_user_from_remote_dir "${REMOTE_DIR:-/home/${PI_USER:-batu}/pi-gateway}")"
    sudo chown "${owner}:${owner}" "$path" 2>/dev/null || true
  fi
}

needs_ssd_storage() {
  # hybrid/ssd-data: ayri /mnt/ssd veri diski
  [[ "${STORAGE_TYPE:-hybrid}" == "hybrid" || "${STORAGE_TYPE:-}" == "ssd-data" ]]
}

# SSD yok ama data/ symlink degil (SD uzerinde native agac) — paneller calisabilir
sd_data_native_ok() {
  local remote="${REMOTE_DIR:-}"
  [[ -n "$remote" && -d "${remote}/data" && ! -L "${remote}/data" ]]
}

# SSD yokken Unbound+AdGuard (core-dns) SD uzerinde — varsayilan acik.
# STORAGE_FALLBACK_SD=true ayni yolu acar (geriye uyum).
# Ikisi de false ise fail-closed (DNS de dusebilir).
dns_degraded_on_ssd_loss() {
  [[ "${DNS_DEGRADED_ON_SSD_LOSS:-true}" == "true" ]] \
    || [[ "${STORAGE_FALLBACK_SD:-false}" == "true" ]]
}

# ssd-root: OS root USB/SSD uzerinde olmali (mmcblk yasak)
is_ssd_root_mode() {
  [[ "${STORAGE_TYPE:-hybrid}" == "ssd-root" || "${STORAGE_TYPE:-hybrid}" == "ssd" ]]
}

root_on_ssd() {
  local src
  src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [[ -n "$src" ]] || return 1
  ! echo "$src" | grep -q 'mmcblk'
}

pi_user_from_remote_dir() {
  local remote_dir="$1"
  if [[ "$remote_dir" =~ /home/([^/]+)/ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "${PI_USER:-batu}"
  fi
}

root_rw_ok() {
  ! findmnt -n -o OPTIONS / 2>/dev/null | tr ',' '\n' | grep -qx 'ro'
}

storage_degraded() {
  [[ -f "${STORAGE_DEGRADED_FLAG}" ]] || return 1
  # Stuck flag iyilestirme: SSD + symlink OK ise bayrak yalan — temizle
  if needs_ssd_storage && mountpoint -q /mnt/ssd 2>/dev/null; then
    local data_link="${REMOTE_DIR:-}/data"
    if [[ -n "${REMOTE_DIR:-}" && -L "$data_link" ]] \
      && [[ "$(readlink -f "$data_link" 2>/dev/null)" == "/mnt/ssd/pi-gateway-data" ]]; then
      clear_storage_degraded 2>/dev/null || true
      [[ -f "${STORAGE_DEGRADED_FLAG}" ]] || return 1
    fi
  fi
  return 0
}

set_storage_degraded() {
  ensure_runtime_dir
  if touch "$STORAGE_DEGRADED_FLAG" 2>/dev/null; then
    return 0
  fi
  runtime_write "$STORAGE_DEGRADED_FLAG" ""
}

clear_storage_degraded() {
  [[ -f "$STORAGE_DEGRADED_FLAG" ]] || return 0
  if runtime_rm "$STORAGE_DEGRADED_FLAG"; then
    return 0
  fi
  logger -t pi-gateway-recover "HATA: degraded flag silinemedi: $STORAGE_DEGRADED_FLAG"
  echo "[stack-health] HATA: degraded flag silinemedi: $STORAGE_DEGRADED_FLAG" >&2
  return 1
}

mark_stack_recover_cooldown() {
  ensure_runtime_dir
  runtime_write "$STACK_RECOVER_COOLDOWN_FILE" "$(date +%s)" || {
    logger -t pi-gateway-recover "WARN: cooldown yazilamadi"
    return 0
  }
}

stack_recover_suppressed() {
  local last_ts now uptime_sec cooldown
  if recover_service_running; then
    return 0
  fi
  cooldown="$STACK_RECOVER_COOLDOWN_SEC"
  if storage_degraded; then
    cooldown="$STACK_RECOVER_COOLDOWN_DEGRADED_SEC"
  fi
  if [[ -f "$STACK_RECOVER_COOLDOWN_FILE" ]]; then
    last_ts="$(cat "$STACK_RECOVER_COOLDOWN_FILE" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if (( now - last_ts < cooldown )); then
      return 0
    fi
  fi
  uptime_sec="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 9999)"
  if (( uptime_sec < STACK_BOOT_GRACE_SEC )) && ! stack_fully_healthy; then
    return 0
  fi
  return 1
}

# Degraded: sadece DNS core (mount sart degil). Tam saglik: gateway dahil.
stack_dns_core_ok() {
  systemctl is-active --quiet docker 2>/dev/null || return 1
  container_health_ok 'adguard' || return 1
  container_health_ok 'unbound' || return 1
  return 0
}

# 0 = saglikli, 1 = unhealthy/none/missing
container_health_ok() {
  local name="$1"
  local status
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name" || return 1
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null)" || return 1
  [[ "$status" == "healthy" || "$status" == "none" ]]
}

# 0 = core ayakta, 1 = bozuk (isim = donus kodu)
stack_core_ok() {
  if needs_ssd_storage && ! storage_degraded; then
    mountpoint -q /mnt/ssd 2>/dev/null || return 1
  fi
  stack_dns_core_ok || return 1
  # Degraded DNS-only: Caddy panel opsiyonel — DNS ayaktaysa core OK
  if storage_degraded; then
    return 0
  fi
  container_health_ok 'caddy' || return 1
  return 0
}

stack_gateway_ok() {
  local domain="${LAN_DOMAIN:-home}"
  local code
  if [[ "${ENABLE_TLS:-false}" == "true" ]]; then
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
      --resolve "gateway.${domain}:443:127.0.0.1" \
      "https://gateway.${domain}/" 2>/dev/null)" || return 1
  else
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      -H "Host: gateway.${domain}" "http://127.0.0.1/" 2>/dev/null)" || return 1
  fi
  [[ "$code" == "200" || "$code" == "401" || "$code" == "302" || "$code" == "307" ]]
}

stack_fully_healthy() {
  stack_core_ok || return 1
  # SSD degraded: Unbound+AdGuard yeterli (panel/Caddy best-effort)
  if storage_degraded; then
    return 0
  fi
  stack_gateway_ok
}

recover_service_running() {
  local state
  state="$(systemctl show -p ActiveState --value pi-gateway-recover-ro.service 2>/dev/null || true)"
  [[ "$state" == "activating" || "$state" == "start" ]] && return 0
  # Script dogrudan cagrildiginda systemd activating olmayabilir — lock dosyasi
  [[ -f "$STACK_LOCK_FILE" ]] && fuser -s "$STACK_LOCK_FILE" 2>/dev/null
}

wait_for_recover_service() {
  local waited=0
  while recover_service_running && (( waited < STACK_RECOVER_WAIT_SEC )); do
    sleep 2
    waited=$((waited + 2))
  done
  ! recover_service_running
}

acquire_recover_lock_wait() {
  local owner
  owner="$(pi_user_from_remote_dir "${REMOTE_DIR:-/home/${PI_USER:-batu}/pi-gateway}")"
  mkdir -p "$(dirname "$STACK_LOCK_FILE")" 2>/dev/null || return 1
  touch "$STACK_LOCK_FILE" 2>/dev/null || return 1
  if [[ "$(id -u)" -eq 0 ]]; then
    chown "${owner}:${owner}" "$STACK_LOCK_FILE" 2>/dev/null || true
  fi
  chmod 664 "$STACK_LOCK_FILE" 2>/dev/null || true
  exec {STACK_LOCK_FD}>>"$STACK_LOCK_FILE" || return 1
  flock -w "${STACK_RECOVER_WAIT_SEC}" "$STACK_LOCK_FD" || return 1
}

release_recover_lock() {
  [[ -n "${STACK_LOCK_FD:-}" ]] || return 0
  flock -u "$STACK_LOCK_FD" 2>/dev/null || true
}

run_compose_up() {
  local remote_dir="$1"
  local pi_user="$2"
  local lib="${PI_GATEWAY_LIB_DIR:-/usr/local/lib/pi-gateway}"
  local script
  # REMOTE_DIR once — rsync sonrasi lib drift olmasin
  if [[ -f "${remote_dir}/scripts/pi/recover-compose-up.sh" ]]; then
    script="${remote_dir}/scripts/pi/recover-compose-up.sh"
  elif [[ -x "${lib}/scripts/pi/recover-compose-up.sh" ]]; then
    script="${lib}/scripts/pi/recover-compose-up.sh"
  else
    script="${remote_dir}/scripts/pi/recover-compose-up.sh"
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "$pi_user" -- env \
      REMOTE_DIR="$remote_dir" \
      COMPOSE_RECOVER_MODE="${COMPOSE_RECOVER_MODE:-}" \
      bash "$script"
  else
    REMOTE_DIR="$remote_dir" COMPOSE_RECOVER_MODE="${COMPOSE_RECOVER_MODE:-}" bash "$script"
  fi
}

recover_script_path() {
  local remote_dir="$1"
  local lib="${PI_GATEWAY_LIB_DIR:-/usr/local/lib/pi-gateway}"
  # Deploy rsync ~/pi-gateway gunceller; systemd lib eski kalabilir — REMOTE once
  if [[ -f "${remote_dir}/scripts/pi/recover-readonly-root.sh" ]]; then
    echo "${remote_dir}/scripts/pi/recover-readonly-root.sh"
  elif [[ -x "${lib}/scripts/pi/recover-readonly-root.sh" ]]; then
    echo "${lib}/scripts/pi/recover-readonly-root.sh"
  else
    echo "${remote_dir}/scripts/pi/recover-readonly-root.sh"
  fi
}

apply_adguard_rewrites_best_effort() {
  local remote_dir="${1:-${REMOTE_DIR:-}}"
  local lib="${PI_GATEWAY_LIB_DIR:-/usr/local/lib/pi-gateway}"
  local script
  local pi_user
  local rc=0
  if [[ -f "${remote_dir}/scripts/pi/apply-adguard-rewrites.sh" ]]; then
    script="${remote_dir}/scripts/pi/apply-adguard-rewrites.sh"
  elif [[ -x "${lib}/scripts/pi/apply-adguard-rewrites.sh" ]]; then
    script="${lib}/scripts/pi/apply-adguard-rewrites.sh"
  else
    script="${remote_dir}/scripts/pi/apply-adguard-rewrites.sh"
  fi
  [[ -x "$script" || -f "$script" ]] || return 0
  pi_user="$(pi_user_from_remote_dir "$remote_dir")"
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "$pi_user" -- env REMOTE_DIR="$remote_dir" bash "$script" >/dev/null 2>&1 || rc=$?
  else
    REMOTE_DIR="$remote_dir" bash "$script" >/dev/null 2>&1 || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    logger -t pi-gateway-recover "WARN adguard rewrite basarisiz (exit $rc)"
    echo "[stack-health] WARN: adguard rewrite basarisiz (exit $rc)" >&2
  fi
  return 0
}

trigger_stack_recover() {
  local remote_dir="${1:-${REMOTE_DIR:-/home/${USER:-batu}/pi-gateway}}"
  local script
  script="$(recover_script_path "$remote_dir")"
  [[ -f "$script" ]] || return 1

  wait_for_recover_service || true

  if stack_fully_healthy && root_rw_ok; then
    apply_adguard_rewrites_best_effort "$remote_dir"
    return 0
  fi

  if stack_recover_suppressed; then
    logger -t pi-gateway-recover "recover atlandi (cooldown/boot grace)"
    return 1
  fi

  if REMOTE_DIR="$remote_dir" bash "$script"; then
    mark_stack_recover_cooldown
    stack_fully_healthy && root_rw_ok
  else
    return 1
  fi
}
