#!/usr/bin/env bash
# SD kart / root dosya sistemi sagligi (read-only, yazma, kernel I/O hatalari)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="pi-gateway-sd-health"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
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
# SD kart I/O = mmcblk. USB SSD (sdb1) EXT4/Buffer I/O usb-ssd-disconnect'e gider;
# aksi halde kernel-io-errors + ssd-health-fail notify_sd_warn ("SD kart degistir") basar.
RECENT_KERNEL_ERRORS="$(
  journalctl -k -b --no-pager --since "15 min ago" 2>/dev/null \
    | grep -iE 'mmcblk.*(error|timeout)|Buffer I/O error on dev mmcblk|ext4.*mmcblk.*(error|checksum)' \
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
# Hybrid: stale mount / I/O → soft-reset → degraded/restore (ssd-health)
if needs_ssd_storage && ! is_ssd_root_mode; then
  if [[ -x "$SCRIPT_DIR/ssd-health.sh" ]] || [[ -f "$SCRIPT_DIR/ssd-health.sh" ]]; then
    # health-check SD_HEALTH_AUTO_RECOVER=false ile gelir; SSD kurtarma ayri env
    SSD_HEALTH_AUTO="${SSD_HEALTH_AUTO:-${SD_HEALTH_AUTO_RECOVER:-true}}"
    export SSD_HEALTH_AUTO
    if ! REMOTE_DIR="$REMOTE_DIR" SSD_HEALTH_AUTO="$SSD_HEALTH_AUTO" bash "$SCRIPT_DIR/ssd-health.sh"; then
      ISSUES+=("ssd-health-fail")
      log "ssd-health kurtarma basarisiz veya degraded"
    elif declare -F ssd_mount_healthy >/dev/null 2>&1 && ssd_mount_healthy; then
      # Tarihsel journal I/O — mount simdi OK ise fail sayma
      _ssd_issues_filtered=()
      for _ssd_issue in "${ISSUES[@]+"${ISSUES[@]}"}"; do
        [[ "$_ssd_issue" == "usb-ssd-disconnect" || "$_ssd_issue" == "ssd-health-fail" ]] && continue
        _ssd_issues_filtered+=("$_ssd_issue")
      done
      ISSUES=("${_ssd_issues_filtered[@]+"${_ssd_issues_filtered[@]}"}")
      unset _ssd_issues_filtered _ssd_issue
    fi
  fi
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
# Tarihsel kernel I/O: root+SSD simdi saglikliysa fail etme (yalniz uyar)
if declare -F ssd_mount_healthy >/dev/null 2>&1 && ssd_mount_healthy && root_rw_ok; then
  _only_hist=1
  for _i in "${ISSUES[@]+"${ISSUES[@]}"}"; do
    case "$_i" in
      kernel-io-errors|usb-ssd-disconnect) ;;
      *) _only_hist=0; break ;;
    esac
  done
  if [[ "$_only_hist" -eq 1 ]]; then
    log "WARN: tarihsel I/O journal — root/SSD simdi OK, fail yok"
    unset _only_hist _i
    exit 0
  fi
  unset _only_hist _i
fi
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
DETAILS="$(printf '%s\n' "${ISSUES[@]}")"
if [[ -n "$RECENT_KERNEL_ERRORS" ]]; then
  DETAILS="$(printf '%s\n\nKernel:\n%s' "$DETAILS" "$RECENT_KERNEL_ERRORS")"
fi
if [[ -n "$USB_SSD_ERRORS" ]]; then
  DETAILS="$(printf '%s\n\nUSB/SSD:\n%s' "$DETAILS" "$USB_SSD_ERRORS")"
fi
_ssd_only=1
_has_ssd_issue=0
for _i in "${ISSUES[@]+"${ISSUES[@]}"}"; do
  case "$_i" in
    ssd-health-fail|usb-ssd-disconnect)
      _has_ssd_issue=1
      ;;
    kernel-io-errors)
      ;;
    *)
      _ssd_only=0
      break
      ;;
  esac
done
if [[ "$_ssd_only" -eq 1 && "$_has_ssd_issue" -eq 0 ]]; then
  _ssd_only=0
fi
if [[ "$_ssd_only" -eq 1 ]]; then
  notify_ssd_degraded "$(hostname -s)" "$DETAILS"
  unset _ssd_only _i
  if root_rw_ok; then
    log "SSD degraded (root rw) — health fail yok; kurtarma pi-ssd-health.timer"
    # shellcheck source=../lib/reset-gateway-units.sh
    source "$SCRIPT_DIR/../lib/reset-gateway-units.sh"
    reset_pi_gateway_failed_units
    exit 0
  fi
  exit 1
fi
unset _ssd_only _i
notify_sd_warn "$(hostname -s)" "$DETAILS" "$RECOVERED"
exit 1
