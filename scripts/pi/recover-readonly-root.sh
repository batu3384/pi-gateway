#!/usr/bin/env bash
# Boot: SSD mount + symlink + read-only root kurtarma + Docker stack
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${PI_USER:-batu}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="pi-gateway-recover"

log() {
  logger -t "$LOG_TAG" "$*"
  echo "[recover-ro] $*"
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && set -a && source "$REMOTE_DIR/.env" && set +a
# shellcheck source=../lib/compose-profiles.sh
source "$SCRIPT_DIR/../lib/compose-profiles.sh"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

STORAGE_TYPE="${STORAGE_TYPE:-hybrid}"
PI_GATEWAY_USER="$(pi_user_from_remote_dir "$REMOTE_DIR")"

needs_ssd() {
  needs_ssd_storage
}

if needs_ssd; then
  bash "$SCRIPT_DIR/ensure-ssd-fstab.sh" || log "WARN: fstab kontrolu basarisiz"
fi

ensure_ssd_mounted() {
  needs_ssd || return 0
  if mountpoint -q /mnt/ssd 2>/dev/null; then
    return 0
  fi
  local attempt
  for attempt in 1 2 3; do
    log "SSD bagli degil — mount denemesi $attempt/3"
    if systemctl start mnt-ssd.mount 2>/dev/null; then
      sleep 2
    fi
    if mountpoint -q /mnt/ssd 2>/dev/null; then
      log "SSD mount OK (systemd)"
      return 0
    fi
    if run_root mount /mnt/ssd 2>/dev/null; then
      log "SSD mount OK (fstab)"
      return 0
    fi
    sleep 3
  done
  log "WARN: SSD mount basarisiz (USB kablo/port kontrol et)"
  return 1
}

ensure_data_symlink() {
  needs_ssd || return 0
  if REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="$STORAGE_TYPE" \
    bash "$SCRIPT_DIR/ensure-data-symlink.sh" repair; then
    return 0
  fi
  log "WARN: data symlink onarimi basarisiz"
  return 1
}

main() {
  if ! acquire_recover_lock_wait; then
    log "HATA: kurtarma kilidi alinamadi (timeout)"
    exit 1
  fi

  if stack_fully_healthy; then
    log "Stack zaten saglikli — kurtarma gerekmedi"
    apply_adguard_rewrites_best_effort "$REMOTE_DIR"
    release_recover_lock
    exit 0
  fi

  if findmnt -n -o OPTIONS / 2>/dev/null | tr ',' '\n' | grep -qx 'ro'; then
    log "Root read-only — remount rw"
    run_root mount -o remount,rw / || log "WARN: remount rw basarisiz"
  fi

  ensure_ssd_mounted || true
  ensure_data_symlink || true
  if needs_ssd && mountpoint -q /mnt/ssd 2>/dev/null; then
    mkdir -p /mnt/ssd/.disk-probe 2>/dev/null || true
  fi

  if ! systemctl is-active --quiet containerd 2>/dev/null; then
    log "containerd baslatiliyor"
    run_root systemctl start containerd || log "WARN: containerd start basarisiz"
    sleep 2
  fi

  if ! systemctl is-active --quiet docker 2>/dev/null; then
    log "docker baslatiliyor"
    run_root systemctl start docker || log "WARN: docker start basarisiz"
    sleep 3
  fi

  if ! stack_core_ok; then
    if [[ -d "$REMOTE_DIR/compose" ]]; then
      log "docker compose up -d"
      if ! run_compose_up "$REMOTE_DIR" "$PI_GATEWAY_USER"; then
        log "WARN: compose up basarisiz — ikinci deneme"
        sleep 2
        run_compose_up "$REMOTE_DIR" "$PI_GATEWAY_USER" || log "WARN: compose up basarisiz"
      fi
      sleep 10
    fi
  fi

  if stack_fully_healthy; then
    log "OK stack ayakta (adguard, unbound, caddy, gateway)"
    apply_adguard_rewrites_best_effort "$REMOTE_DIR"
    release_recover_lock
    exit 0
  fi

  log "WARN: stack eksik — adguard/unbound/caddy veya gateway erisimi yok"
  release_recover_lock
  exit 1
}

main "$@"
