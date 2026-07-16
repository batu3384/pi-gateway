#!/usr/bin/env bash
# SD kart / root dosya sistemi sagligi (read-only, yazma, kernel I/O hatalari)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="pi-gateway-sd-health"

# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && set -a && source "$REMOTE_DIR/.env" && set +a
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

SD_HEALTH_AUTO_RECOVER="${SD_HEALTH_AUTO_RECOVER:-true}"
ISSUES=()
RECOVERED=0

log() {
  logger -t "$LOG_TAG" "$*"
  echo "[sd-health] $*"
}

root_readonly() {
  findmnt -n -o OPTIONS / 2>/dev/null | tr ',' '\n' | grep -qx 'ro'
}

run_recover() {
  [[ "$SD_HEALTH_AUTO_RECOVER" == "true" ]] || return 1
  trigger_stack_recover "$REMOTE_DIR"
}

if root_readonly; then
  log "Root read-only tespit edildi"
  if run_recover; then
    if root_readonly; then
      log "Kurtarma tamamlandi ama root hala read-only"
    else
      RECOVERED=1
      log "Otomatik kurtarma basarili — root tekrar yazilabilir"
    fi
  else
    log "Otomatik kurtarma basarisiz"
  fi
fi

if root_readonly; then
  ISSUES+=("root-readonly")
fi

if ! touch "${REMOTE_DIR}/.sd-write-test" 2>/dev/null; then
  ISSUES+=("root-not-writable")
  log "Root yazma testi basarisiz"
else
  rm -f "${REMOTE_DIR}/.sd-write-test"
fi

RECENT_KERNEL_ERRORS="$(
  journalctl -k -b --no-pager --since "15 min ago" 2>/dev/null \
    | grep -iE 'ext4.*(error|checksum)|I/O error|mmcblk.*(error|timeout)|Buffer I/O error' \
    | grep -vi 'orphan cleanup on readonly' \
    | tail -5 || true
)"

if [[ -n "$RECENT_KERNEL_ERRORS" ]]; then
  ISSUES+=("kernel-io-errors")
  log "Son 15 dk kernel I/O uyarisi"
fi

USB_SSD_ERRORS="$(
  journalctl -k -b --no-pager --since "15 min ago" 2>/dev/null \
    | grep -iE 'usb .*disconnect|I/O error.*sd[a-z]|Buffer I/O error on dev sd|reset.*USB' \
    | tail -5 || true
)"
if [[ -n "$USB_SSD_ERRORS" ]]; then
  ISSUES+=("usb-ssd-disconnect")
  log "Son 15 dk USB/SSD kopma veya I/O hatasi"
fi

if [[ ${#ISSUES[@]} -eq 0 ]]; then
  log "OK root rw, yazma testi gecti"
  if [[ "$RECOVERED" -eq 1 ]]; then
    # shellcheck source=../lib/notify.sh
    source "$SCRIPT_DIR/../lib/notify.sh"
    notify_sd_recovered "$(hostname -s)"
  fi
  exit 0
fi

# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
DETAILS="$(printf '%s\n' "${ISSUES[@]}")"
if [[ -n "$RECENT_KERNEL_ERRORS" ]]; then
  DETAILS="$(printf '%s\n\nKernel:\n%s' "$DETAILS" "$RECENT_KERNEL_ERRORS")"
fi
notify_sd_warn "$(hostname -s)" "$DETAILS" "$RECOVERED"
exit 1
