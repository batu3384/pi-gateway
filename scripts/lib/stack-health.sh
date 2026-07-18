#!/usr/bin/env bash
# Stack sagligi ve kurtarma kilidi (health-check, watchdog, recover-ro)
set -euo pipefail

# recover-ro TimeoutStartSec (360) altinda kalmali; waiter biraz daha uzun bekler
STACK_RECOVER_WAIT_SEC="${STACK_RECOVER_WAIT_SEC:-330}"
STACK_LOCK_FILE="${STACK_LOCK_FILE:-/run/pi-gateway/stack-recover.lock}"
STORAGE_DEGRADED_FLAG="${STORAGE_DEGRADED_FLAG:-/run/pi-gateway/storage-degraded}"
STACK_RECOVER_COOLDOWN_SEC="${STACK_RECOVER_COOLDOWN_SEC:-180}"
STACK_RECOVER_COOLDOWN_FILE="${STACK_RECOVER_COOLDOWN_FILE:-/run/pi-gateway/stack-recover-cooldown}"
STACK_BOOT_GRACE_SEC="${STACK_BOOT_GRACE_SEC:-120}"
SSD_HOTPLUG_STATE_FILE="${SSD_HOTPLUG_STATE_FILE:-/var/lib/pi-gateway/ssd-hotplug-mounted}"
SSD_HOTPLUG_DEBOUNCE_SEC="${SSD_HOTPLUG_DEBOUNCE_SEC:-120}"

needs_ssd_storage() {
  # hybrid/ssd-data: ayri /mnt/ssd veri diski
  [[ "${STORAGE_TYPE:-hybrid}" == "hybrid" || "${STORAGE_TYPE:-}" == "ssd-data" ]]
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
  [[ -f "${STORAGE_DEGRADED_FLAG}" ]]
}

set_storage_degraded() {
  mkdir -p "$(dirname "$STORAGE_DEGRADED_FLAG")" 2>/dev/null || true
  touch "$STORAGE_DEGRADED_FLAG" 2>/dev/null || true
}

clear_storage_degraded() {
  rm -f "$STORAGE_DEGRADED_FLAG" 2>/dev/null || true
}

mark_stack_recover_cooldown() {
  mkdir -p "$(dirname "$STACK_RECOVER_COOLDOWN_FILE")" 2>/dev/null || true
  date +%s >"$STACK_RECOVER_COOLDOWN_FILE" 2>/dev/null || true
}

stack_recover_suppressed() {
  local then now uptime_sec
  if recover_service_running; then
    return 0
  fi
  if [[ -f "$STACK_RECOVER_COOLDOWN_FILE" ]]; then
    then="$(cat "$STACK_RECOVER_COOLDOWN_FILE" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if (( now - then < STACK_RECOVER_COOLDOWN_SEC )); then
      return 0
    fi
  fi
  uptime_sec="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 9999)"
  if (( uptime_sec < STACK_BOOT_GRACE_SEC )) && ! stack_fully_healthy; then
    return 0
  fi
  return 1
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
  systemctl is-active --quiet docker 2>/dev/null || return 1
  container_health_ok 'adguard' || return 1
  container_health_ok 'unbound' || return 1
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
  local script="${lib}/scripts/pi/recover-compose-up.sh"
  [[ -x "$script" ]] || script="${remote_dir}/scripts/pi/recover-compose-up.sh"
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "$pi_user" -- env REMOTE_DIR="$remote_dir" bash "$script"
  else
    REMOTE_DIR="$remote_dir" bash "$script"
  fi
}

recover_script_path() {
  local remote_dir="$1"
  local lib="${PI_GATEWAY_LIB_DIR:-/usr/local/lib/pi-gateway}"
  if [[ -x "${lib}/scripts/pi/recover-readonly-root.sh" ]]; then
    echo "${lib}/scripts/pi/recover-readonly-root.sh"
  else
    echo "${remote_dir}/scripts/pi/recover-readonly-root.sh"
  fi
}

apply_adguard_rewrites_best_effort() {
  local remote_dir="${1:-${REMOTE_DIR:-}}"
  local lib="${PI_GATEWAY_LIB_DIR:-/usr/local/lib/pi-gateway}"
  local script="${lib}/scripts/pi/apply-adguard-rewrites.sh"
  local pi_user
  local rc=0
  [[ -x "$script" ]] || script="${remote_dir}/scripts/pi/apply-adguard-rewrites.sh"
  [[ -x "$script" ]] || return 0
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
