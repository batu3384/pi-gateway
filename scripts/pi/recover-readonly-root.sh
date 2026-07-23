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

# hybrid kalintisi: ssd-root'ta /mnt/ssd fstab yok
if needs_ssd; then
  # Health/recover dongusunda 15x2s beklemeyi kes — disk yoksa hizli degraded
  local_fstab_attempts=15
  if dns_degraded_on_ssd_loss && ! mountpoint -q /mnt/ssd 2>/dev/null; then
    local_fstab_attempts="${ENSURE_FSTAB_MAX_ATTEMPTS:-3}"
  fi
  ENSURE_FSTAB_MAX_ATTEMPTS="$local_fstab_attempts" bash "$SCRIPT_DIR/ensure-ssd-fstab.sh" \
    || log "WARN: fstab kontrolu basarisiz"
fi

if is_ssd_root_mode && ! root_on_ssd; then
  log "HATA: STORAGE_TYPE=ssd-root ama root mmcblk — cutover/EEPROM onar (repair-cutover-bootfs.sh)"
  exit 1
fi

ensure_root_rw() {
  if root_rw_ok; then
    return 0
  fi
  log "Root read-only — remount rw (lock oncesi)"
  run_root mount -o remount,rw / || {
    log "HATA: remount rw basarisiz"
    return 1
  }
  root_rw_ok
}

ensure_ssd_mounted() {
  needs_ssd || return 0
  if mountpoint -q /mnt/ssd 2>/dev/null; then
    clear_storage_degraded
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
      clear_storage_degraded
      return 0
    fi
    if run_root mount /mnt/ssd 2>/dev/null; then
      log "SSD mount OK (fstab)"
      clear_storage_degraded
      return 0
    fi
    sleep 3
  done
  log "WARN: SSD mount basarisiz"
  return 1
}

ensure_data_symlink() {
  needs_ssd || return 0
  if storage_degraded; then
    if REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="$STORAGE_TYPE" \
      bash "$SCRIPT_DIR/ensure-data-symlink.sh" repair --fallback-sd; then
      return 0
    fi
    log "WARN: SD fallback symlink basarisiz"
    return 1
  fi
  if REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="$STORAGE_TYPE" \
    bash "$SCRIPT_DIR/ensure-data-symlink.sh" repair; then
    return 0
  fi
  log "WARN: data symlink onarimi basarisiz"
  return 1
}

enter_degraded_mode() {
  log "SSD yok — degraded mod (SD fallback DNS)"
  set_storage_degraded
  REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="$STORAGE_TYPE" \
    bash "$SCRIPT_DIR/ensure-data-symlink.sh" repair --fallback-sd || true
  if [[ -x "$SCRIPT_DIR/setup-docker-fallback.sh" ]]; then
    REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/setup-docker-fallback.sh" || log "WARN: docker SD fallback basarisiz"
  fi
  # shellcheck source=../lib/notify.sh
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_ssd_degraded "$(hostname -s)" "SSD mount yok — core DNS SD uzerinde"
}

run_compose_recover() {
  local mode="${1:-full}"
  if [[ "$mode" == "core-dns" ]]; then
    COMPOSE_RECOVER_MODE=core-dns run_compose_up "$REMOTE_DIR" "$PI_GATEWAY_USER"
  else
    run_compose_up "$REMOTE_DIR" "$PI_GATEWAY_USER"
  fi
}

main() {
  if ! ensure_root_rw; then
    exit 1
  fi

  if ! acquire_recover_lock_wait; then
    log "HATA: kurtarma kilidi alinamadi (timeout)"
    exit 1
  fi

  if stack_fully_healthy && root_rw_ok; then
    log "Stack saglikli ve root rw — kurtarma gerekmedi"
    apply_adguard_rewrites_best_effort "$REMOTE_DIR"
    release_recover_lock
    exit 0
  fi

  local recover_mode="full"
  if needs_ssd; then
    if ensure_ssd_mounted; then
      :
    elif dns_degraded_on_ssd_loss; then
      enter_degraded_mode
      recover_mode="core-dns"
    else
      log "HATA: SSD mount basarisiz ve DNS_DEGRADED_ON_SSD_LOSS=false (fail-closed)"
      release_recover_lock
      exit 1
    fi
  fi

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
      log "docker compose up -d (mode=$recover_mode)"
      if ! run_compose_recover "$recover_mode"; then
        log "WARN: compose up basarisiz — ikinci deneme"
        sleep 2
        run_compose_recover "$recover_mode" || log "WARN: compose up basarisiz"
      fi
      sleep 10
    fi
  fi

  if stack_fully_healthy && root_rw_ok; then
    if storage_degraded; then
      log "OK degraded DNS ayakta (adguard, unbound)"
    else
      log "OK stack ayakta (adguard, unbound, caddy, gateway)"
    fi
    apply_adguard_rewrites_best_effort "$REMOTE_DIR"
    release_recover_lock
    exit 0
  fi

  if storage_degraded && stack_dns_core_ok && root_rw_ok; then
    log "OK degraded DNS core ayakta (gateway/caddy eksik olabilir)"
    apply_adguard_rewrites_best_effort "$REMOTE_DIR"
    release_recover_lock
    exit 0
  fi

  log "WARN: stack eksik — adguard/unbound/caddy veya gateway erisimi yok"
  release_recover_lock
  exit 1
}

main "$@"
