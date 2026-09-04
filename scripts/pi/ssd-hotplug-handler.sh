#!/usr/bin/env bash
# SSD hotplug: kopma / yeniden takilma (+ stale mount + soft-reset)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${PI_USER:-pi}/pi-gateway}"
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
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[ssd-hotplug] HATA: .env dotenv parser hatasi" >&2; exit 1; }
_HOTPLUG_REMOTE_DIR="$REMOTE_DIR"
REMOTE_DIR="$_HOTPLUG_REMOTE_DIR"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"
if ssd_find_usb_sysfs >/dev/null 2>&1; then
  if ssd_usb_learn_live_port 2>/dev/null; then
    log "USB enumerate — port kaydi guncellendi"
  fi
fi
if is_ssd_root_mode; then
  log "ssd-root: hotplug handler atlandi"
  exit 0
fi
# Stale mount: mountpoint var ama I/O olu — lazy umount + soft-reset
if mountpoint -q /mnt/ssd 2>/dev/null && ! ssd_mount_healthy; then
  log "Stale/hung SSD mount — umount + soft-reset"
  run_root umount -l /mnt/ssd 2>/dev/null || true
  ssd_usb_soft_reset || log "WARN: soft-reset basarisiz"
fi
# Henuz mount degil ama block var — remount dene
if ! ssd_mount_healthy && ssd_block_present; then
  log "SSD block var, mount yok — remount"
  if ! ssd_try_remount; then
    log "remount fail — soft-reset"
    ssd_usb_soft_reset || true
  fi
fi
if ssd_mount_healthy; then
  # Degraded bayrak varken asla early-exit — tam stack restore zorunlu
  if [[ ! -f "${STORAGE_DEGRADED_FLAG:-/run/pi-gateway/storage-degraded}" ]] \
    && [[ -f "$SSD_HOTPLUG_STATE_FILE" ]] \
    && stack_core_ok 2>/dev/null \
    && docker_sandbox_ok 2>/dev/null; then
    log "SSD saglikli ve stack core + docker sandbox ayakta — atlaniyor"
    exit 0
  fi
  if hotplug_debounced \
    && [[ ! -f "${STORAGE_DEGRADED_FLAG:-/run/pi-gateway/storage-degraded}" ]]; then
    log "debounce (${SSD_HOTPLUG_DEBOUNCE_SEC}s) — atlaniyor"
    exit 0
  fi
  touch_hotplug_run
  log "SSD mount OK — tam stack restore"
  if ! recover_lock_acquire; then
    log "HATA: kurtarma kilidi alinamadi (timeout)"
    exit 1
  fi
  ensure_runtime_dir
  # fstab drift onarimi + acik remount (flag HENUZ silinmez)
  if [[ -x "$SCRIPT_DIR/ensure-ssd-fstab.sh" ]]; then
    REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/ensure-ssd-fstab.sh" || log "WARN: ensure-fstab"
  fi
  ssd_try_remount || log "WARN: remount"
  if ! REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/ensure-data-symlink.sh" repair; then
    log "HATA: SSD data symlink onarimi basarisiz"
    recover_lock_release
    exit 1
  fi
  if [[ -x "$SCRIPT_DIR/setup-docker-ssd.sh" ]] && [[ "${ENABLE_DOCKER_SSD:-false}" == "true" ]]; then
    if ! REMOTE_DIR="$REMOTE_DIR" SKIP_COMPOSE_UP=true bash "$SCRIPT_DIR/setup-docker-ssd.sh"; then
      log "HATA: docker SSD restore basarisiz"
      recover_lock_release
      exit 1
    fi
    if ! docker_ssd_root_ok; then
      log "HATA: docker root SSD'de degil ($(docker_data_root || echo bilinmiyor))"
      recover_lock_release
      exit 1
    fi
  fi
  if ! REMOTE_DIR="$REMOTE_DIR" SKIP_RECOVER_LOCK=true bash "$(recover_script_path "$REMOTE_DIR")"; then
    log "HATA: recover basarisiz — degraded flag korunuyor"
    # shellcheck source=../lib/notify.sh
    source "$SCRIPT_DIR/../lib/notify.sh"
    notify_ssd_recovery_failed "$(hostname -s)" "SSD bağlı; tam servis kurtarma başarısız."
    recover_lock_release
    exit 1
  fi
  # Recover success gate (full stack) — flag clear recover icinde; burada dogrula
  if storage_degraded; then
    log "WARN: recover bitti ama degraded flag duruyor — clear deneniyor"
    if stack_dns_core_ok && { [[ "${ENABLE_CADDY:-true}" != "true" ]] || container_health_ok caddy; } \
      && { [[ "${ENABLE_CADDY:-true}" != "true" ]] || stack_gateway_ok; } \
      && docker_ssd_root_ok; then
      clear_storage_degraded || log "WARN: degraded flag temizlenemedi"
    else
      recover_lock_release
      exit 1
    fi
  fi
  run_root mkdir -p "$(dirname "$SSD_HOTPLUG_STATE_FILE")" 2>/dev/null || true
  run_root touch "$SSD_HOTPLUG_STATE_FILE" 2>/dev/null || true
  mark_stack_recover_cooldown
  REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/repair-post-ssd-recovery.sh" \
    || log "WARN: post-ssd repair"
  # SSD recovery notification is owned by recover-readonly-root.sh.
  ssd_usb_reset_clear 2>/dev/null || true
  ssd_ghost_block_cleanup 2>/dev/null || true
  ssd_purge_stale_block_devs 2>/dev/null || true
  if declare -F ssd_filesystem_needs_fsck >/dev/null 2>&1 && ssd_filesystem_needs_fsck; then
    log "WARN: aktif SSD ext4 fsck gerekli — SSD_FSCK_AUTO veya ssd-fsck.sh --run"
    if [[ "${SSD_FSCK_AUTO:-false}" == "true" ]] && [[ -x "$SCRIPT_DIR/ssd-fsck.sh" ]]; then
      REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/ssd-fsck.sh" --run \
        || log "WARN: otomatik fsck basarisiz"
    fi
  fi
  recover_lock_release
  exit 0
fi
log "SSD mount yok / sagliksiz"
run_root rm -f "$SSD_HOTPLUG_STATE_FILE" 2>/dev/null || true
# Soft-reset bir kez daha (cihaz yarim enumerate) — reentry korumasi
if [[ "${SSD_HOTPLUG_REENTRY:-0}" != "1" ]] && ssd_usb_soft_reset && ssd_mount_healthy; then
  log "soft-reset sonrasi SSD saglikli — restore'a don"
  exec env SSD_HOTPLUG_REENTRY=1 REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/ssd-hotplug-handler.sh"
fi
# Degraded oncesi stale mount kalintisini temizle (symlink clear bug onleme)
if mountpoint -q /mnt/ssd 2>/dev/null && ! ssd_mount_healthy; then
  run_root umount -l /mnt/ssd 2>/dev/null || true
fi
if ! dns_degraded_on_ssd_loss; then
  log "HATA: DNS_DEGRADED_ON_SSD_LOSS=false — degraded moda gecilmiyor (fail-closed)"
  # shellcheck source=../lib/notify.sh
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_ssd_degraded "$(hostname -s)" "SSD kopma — DNS korumalı kapatma politikası etkin"
  exit 1
fi
log "DNS degraded moda gecis (core-dns SD)"
if ! recover_lock_acquire; then
  log "HATA: kurtarma kilidi alinamadi (timeout)"
  exit 1
fi
degraded_stop_optional_apps "$REMOTE_DIR"
set_storage_degraded
if ! REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/ensure-data-symlink.sh" repair --fallback-sd; then
  log "HATA: SD fallback data symlink onarimi basarisiz"
  recover_lock_release
  exit 1
fi
if ! REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/setup-docker-fallback.sh"; then
  log "HATA: Docker SD fallback basarisiz"
  recover_lock_release
  exit 1
fi
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
compose_rc=0
if [[ -d "$REMOTE_DIR/compose" ]]; then
  if COMPOSE_RECOVER_MODE=core-dns run_compose_up \
    "$REMOTE_DIR" "$(pi_user_from_remote_dir "$REMOTE_DIR")"; then
    :
  else
    compose_rc=$?
    log "HATA: core-dns compose basarisiz (exit $compose_rc)"
  fi
fi
if [[ "$compose_rc" -ne 0 ]]; then
  notify_ssd_degraded "$(hostname -s)" \
    "USB SSD kopma — çekirdek DNS compose kurtarması başarısız"
  recover_lock_release
  exit "$compose_rc"
fi
notify_ssd_degraded "$(hostname -s)" "USB SSD kopma — DNS SD karttan devam ediyor"
mark_stack_recover_cooldown
recover_lock_release
# shellcheck source=../lib/reset-gateway-units.sh
source "$SCRIPT_DIR/../lib/reset-gateway-units.sh"
reset_pi_gateway_failed_units
exit 0
