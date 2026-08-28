#!/usr/bin/env bash
# Boot: SSD mount + symlink + read-only root kurtarma + Docker stack
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${PI_USER:-pi}/pi-gateway}"
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
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[recover-ro] HATA: .env dotenv parser hatasi" >&2; exit 1; }
_RECOVER_REMOTE_DIR="$REMOTE_DIR"
REMOTE_DIR="$_RECOVER_REMOTE_DIR"
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
  # Stale mount: mountpoint true ama I/O olu — degraded clear YASAK (hotplug/recover success clear)
  if declare -F ssd_mount_healthy >/dev/null 2>&1; then
    if ssd_mount_healthy; then
      return 0
    fi
  elif mountpoint -q /mnt/ssd 2>/dev/null; then
    return 0
  fi
  local attempt
  for attempt in 1 2 3; do
    log "SSD bagli degil/sagliksiz — mount denemesi $attempt/3"
    if systemctl start mnt-ssd.mount 2>/dev/null; then
      sleep 2
    fi
    if declare -F ssd_mount_healthy >/dev/null 2>&1; then
      if ssd_mount_healthy; then
        log "SSD mount OK (systemd+probe)"
        return 0
      fi
    elif mountpoint -q /mnt/ssd 2>/dev/null; then
      log "SSD mount OK (systemd)"
      return 0
    fi
    run_root mount /mnt/ssd 2>/dev/null || true
    if declare -F ssd_mount_healthy >/dev/null 2>&1; then
      if ssd_mount_healthy; then
        log "SSD mount OK (fstab+probe)"
        return 0
      fi
    elif mountpoint -q /mnt/ssd 2>/dev/null; then
      log "SSD mount OK (fstab)"
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
    if storage_restore_pending; then
      log "SSD geri dondu — data symlink SSD'ye onariliyor"
    elif REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="$STORAGE_TYPE" \
      bash "$SCRIPT_DIR/ensure-data-symlink.sh" repair --fallback-sd; then
      return 0
    else
      log "WARN: SD fallback symlink basarisiz"
      return 1
    fi
  fi
  if REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="$STORAGE_TYPE" \
    bash "$SCRIPT_DIR/ensure-data-symlink.sh" repair; then
    return 0
  fi
  log "WARN: data symlink onarimi basarisiz"
  return 1
}
RECOVER_DID_WORK=0
enter_degraded_mode() {
  log "SSD yok — degraded mod (core-dns: Unbound+AdGuard SD)"
  ensure_runtime_dir
  set_storage_degraded
  degraded_stop_optional_apps "$REMOTE_DIR"
  REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="$STORAGE_TYPE" \
    bash "$SCRIPT_DIR/ensure-data-symlink.sh" repair --fallback-sd || true
  if [[ -x "$SCRIPT_DIR/setup-docker-fallback.sh" ]]; then
    REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/setup-docker-fallback.sh" || log "WARN: docker SD fallback basarisiz"
  fi
  # shellcheck source=../lib/notify.sh
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_ssd_degraded "$(hostname -s)" "Veri diski bağlı değil — DNS SD karttan devam ediyor."
  RECOVER_DID_WORK=1
}
run_compose_recover() {
  local mode="${1:-full}"
  if [[ "$mode" == "core-dns" ]]; then
    COMPOSE_RECOVER_MODE=core-dns run_compose_up "$REMOTE_DIR" "$PI_GATEWAY_USER"
  else
    run_compose_up "$REMOTE_DIR" "$PI_GATEWAY_USER"
  fi
  RECOVER_DID_WORK=1
}
_notify_stack_ok() {
  [[ "${RECOVER_DID_WORK:-0}" -eq 1 ]] || return 0
  # shellcheck source=../lib/notify.sh
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_stack_recovered "$(hostname -s)" "${1:-Kurtarma tamamlandı.}"
}
main() {
  if ! ensure_root_rw; then
    exit 1
  fi
  if ! recover_lock_acquire; then
    log "HATA: kurtarma kilidi alinamadi (timeout)"
    exit 1
  fi
  if ! storage_restore_pending && stack_fully_healthy && root_rw_ok; then
    log "Stack saglikli ve root rw — kurtarma gerekmedi"
    apply_adguard_rewrites_best_effort "$REMOTE_DIR"
    recover_lock_release
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
      recover_lock_release
      exit 1
    fi
  fi
  if ! ensure_data_symlink; then
    log "HATA: data symlink onarimi basarisiz"
    recover_lock_release
    exit 1
  fi
  # Degraded fallback sonrasi watchdog/health yolu: Docker root SD'de kalabilir
  if [[ "$recover_mode" == "full" ]] \
    && [[ "${ENABLE_DOCKER_SSD:-false}" == "true" ]] \
    && { ! declare -F ssd_mount_healthy >/dev/null 2>&1 || ssd_mount_healthy; }; then
    if [[ -f "$SCRIPT_DIR/setup-docker-ssd.sh" ]]; then
      log "Docker SSD root dogrulaniyor (recover-ro)"
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
  fi
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
  local was_degraded=0
  storage_degraded && was_degraded=1
  # Full stack (SSD saglikli + DNS + caddy + gateway): degraded bayragini burada temizle
  if root_rw_ok \
    && (! needs_ssd || { declare -F ssd_mount_healthy >/dev/null 2>&1 && ssd_mount_healthy; }) \
    && docker_ssd_root_ok \
    && stack_dns_core_ok \
    && { [[ "${ENABLE_CADDY:-true}" != "true" ]] || container_health_ok caddy; } \
    && { [[ "${ENABLE_CADDY:-true}" != "true" ]] || stack_gateway_ok; } \
    && (! needs_ssd || [[ "$(readlink -f "$REMOTE_DIR/data" 2>/dev/null)" == "/mnt/ssd/pi-gateway-data" ]]); then
    clear_storage_degraded || log "WARN: degraded flag temizlenemedi"
    log "OK stack ayakta (adguard, unbound, caddy, gateway)"
    apply_adguard_rewrites_best_effort "$REMOTE_DIR"
    if [[ "$was_degraded" -eq 1 ]]; then
      # shellcheck source=../lib/notify.sh
      source "$SCRIPT_DIR/../lib/notify.sh"
      notify_ssd_restored "$(hostname -s)" "Yazılımsal kurtarma tamamlandı; tam servisler geri yüklendi."
    else
      _notify_stack_ok "Çekirdek servisler ayakta (DNS + panel)."
    fi
    recover_lock_release
    exit 0
  fi
  if storage_degraded && stack_dns_core_ok && root_rw_ok; then
    log "OK degraded DNS core ayakta (gateway/caddy eksik olabilir)"
    apply_adguard_rewrites_best_effort "$REMOTE_DIR"
    _notify_stack_ok "Kısıtlı mod: DNS ayakta (veri diski yok)."
    recover_lock_release
    exit 0
  fi
  if ! storage_restore_pending && stack_fully_healthy && root_rw_ok && docker_ssd_root_ok; then
    log "OK stack_fully_healthy"
    apply_adguard_rewrites_best_effort "$REMOTE_DIR"
    _notify_stack_ok "Tüm servisler sağlıklı."
    recover_lock_release
    exit 0
  fi
  log "WARN: stack eksik — adguard/unbound/caddy veya gateway erisimi yok"
  recover_lock_release
  exit 1
}
main "$@"
