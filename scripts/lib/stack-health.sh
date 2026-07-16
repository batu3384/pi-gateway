#!/usr/bin/env bash
# Stack sagligi ve kurtarma kilidi (health-check, watchdog, recover-ro)
set -euo pipefail

STACK_LOCK_FILE="${STACK_LOCK_FILE:-/tmp/pi-gateway-recover.lock}"
STACK_RECOVER_WAIT_SEC="${STACK_RECOVER_WAIT_SEC:-120}"

needs_ssd_storage() {
  [[ "${STORAGE_TYPE:-hybrid}" == "hybrid" || "${STORAGE_TYPE:-}" == "ssd-data" ]]
}

stack_core_broken() {
  local broken=0
  if needs_ssd_storage; then
    mountpoint -q /mnt/ssd 2>/dev/null || broken=1
  fi
  systemctl is-active --quiet docker 2>/dev/null || broken=1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'adguard' || broken=1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'unbound' || broken=1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'caddy' || broken=1
  return "$broken"
}

stack_gateway_ok() {
  local domain="${LAN_DOMAIN:-home}"
  if [[ "${ENABLE_TLS:-false}" == "true" ]]; then
    curl -sfk -o /dev/null --max-time 5 \
      --resolve "gateway.${domain}:443:127.0.0.1" \
      "https://gateway.${domain}/" 2>/dev/null
  else
    curl -sf -o /dev/null --max-time 5 -H "Host: gateway.${domain}" "http://127.0.0.1/" 2>/dev/null
  fi
}

stack_fully_healthy() {
  stack_core_broken && return 1
  stack_gateway_ok
}

recover_service_running() {
  [[ "$(systemctl show -p ActiveState --value pi-gateway-recover-ro.service 2>/dev/null || true)" == "activating" ]]
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
  exec {STACK_LOCK_FD}>"$STACK_LOCK_FILE"
  flock -w "${STACK_RECOVER_WAIT_SEC}" "$STACK_LOCK_FD" || return 1
}

release_recover_lock() {
  flock -u "$STACK_LOCK_FD" 2>/dev/null || true
}

run_compose_up() {
  local remote_dir="$1"
  local pi_user="$2"
  local script="${remote_dir}/scripts/pi/recover-compose-up.sh"
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "$pi_user" -- env REMOTE_DIR="$remote_dir" bash "$script"
  else
    REMOTE_DIR="$remote_dir" bash "$script"
  fi
}

pi_user_from_remote_dir() {
  local remote_dir="$1"
  if [[ "$remote_dir" =~ /home/([^/]+)/ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "${PI_USER:-batu}"
  fi
}

recover_script_path() {
  local remote_dir="$1"
  echo "${remote_dir}/scripts/pi/recover-readonly-root.sh"
}

trigger_stack_recover() {
  local remote_dir="${1:-${REMOTE_DIR:-/home/${USER:-batu}/pi-gateway}}"
  local script
  script="$(recover_script_path "$remote_dir")"
  [[ -f "$script" ]] || return 1

  wait_for_recover_service || true

  if stack_fully_healthy; then
    return 0
  fi

  if REMOTE_DIR="$remote_dir" bash "$script"; then
    stack_fully_healthy
  else
    return 1
  fi
}
