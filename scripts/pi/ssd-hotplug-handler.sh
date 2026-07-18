#!/usr/bin/env bash
# SSD hotplug: kopma / yeniden takilma
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${PI_USER:-batu}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="pi-gateway-ssd-hotplug"
SSD_HOTPLUG_DEBOUNCE_FILE="${SSD_HOTPLUG_DEBOUNCE_FILE:-/var/lib/pi-gateway/ssd-hotplug-last-run}"

log() {
  logger -t "$LOG_TAG" "$*"
  echo "[ssd-hotplug] $*"
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

hotplug_debounced() {
  local last now
  [[ -f "$SSD_HOTPLUG_DEBOUNCE_FILE" ]] || return 1
  last="$(cat "$SSD_HOTPLUG_DEBOUNCE_FILE" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  (( now - last < SSD_HOTPLUG_DEBOUNCE_SEC ))
}

touch_hotplug_run() {
  run_root mkdir -p "$(dirname "$SSD_HOTPLUG_DEBOUNCE_FILE")" 2>/dev/null || true
  date +%s | run_root tee "$SSD_HOTPLUG_DEBOUNCE_FILE" >/dev/null 2>&1 || true
}

# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && set -a && source "$REMOTE_DIR/.env" && set +a
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

if is_ssd_root_mode; then
  log "ssd-root: hotplug handler atlandi"
  exit 0
fi

if mountpoint -q /mnt/ssd 2>/dev/null; then
  if [[ -f "$SSD_HOTPLUG_STATE_FILE" ]] && stack_core_ok 2>/dev/null; then
    log "SSD zaten mount ve stack core ayakta — atlaniyor"
    exit 0
  fi
  if hotplug_debounced; then
    log "debounce (${SSD_HOTPLUG_DEBOUNCE_SEC}s) — atlaniyor"
    exit 0
  fi
  touch_hotplug_run
  log "SSD mount OK — tam stack restore"
  clear_storage_degraded
  REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/ensure-data-symlink.sh" repair || true
  if [[ -x "$SCRIPT_DIR/setup-docker-ssd.sh" ]] && [[ "${ENABLE_DOCKER_SSD:-false}" == "true" ]]; then
    REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/setup-docker-ssd.sh" || log "WARN: docker SSD restore atlandi"
  fi
  run_root systemctl restart docker 2>/dev/null || true
  REMOTE_DIR="$REMOTE_DIR" bash "$(recover_script_path "$REMOTE_DIR")" || log "WARN: recover basarisiz"
  run_root mkdir -p "$(dirname "$SSD_HOTPLUG_STATE_FILE")" 2>/dev/null || true
  run_root touch "$SSD_HOTPLUG_STATE_FILE" 2>/dev/null || true
  mark_stack_recover_cooldown
  # shellcheck source=../lib/notify.sh
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_ssd_restored "$(hostname -s)"
  exit 0
fi

log "SSD mount yok"
run_root rm -f "$SSD_HOTPLUG_STATE_FILE" 2>/dev/null || true
if [[ "${STORAGE_FALLBACK_SD:-false}" != "true" ]]; then
  log "HATA: STORAGE_FALLBACK_SD=false — degraded moda gecilmiyor"
  # shellcheck source=../lib/notify.sh
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_ssd_degraded "$(hostname -s)" "SSD kopma — fail-closed (STORAGE_FALLBACK_SD=false)"
  exit 1
fi

log "STORAGE_FALLBACK_SD=true — degraded moda gecis"
if [[ -d "$REMOTE_DIR/compose" ]]; then
  cd "$REMOTE_DIR/compose"
  docker compose stop n8n forgejo syncthing uptime-kuma crowdsec redis dozzle 2>/dev/null || true
fi
set_storage_degraded
REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/ensure-data-symlink.sh" repair --fallback-sd || true
REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/setup-docker-fallback.sh" || true
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
notify_ssd_degraded "$(hostname -s)" "USB SSD kopma veya mount kaybi"
