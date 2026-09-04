#!/usr/bin/env bash
# SSD saglik gozcusu: stale/I/O → remount / soft-reset → degraded / restore poll
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="pi-gateway-ssd-health"
SSD_HEALTH_AUTO="${SSD_HEALTH_AUTO:-true}"
log() {
  logger -t "$LOG_TAG" "$*"
  echo "[ssd-health] $*"
}
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/stack-health.sh"
ensure_runtime_dir 2>/dev/null || true
if is_ssd_root_mode || ! needs_ssd_storage; then
  log "SSD data disk yok (ssd-root/native) — atlaniyor"
  exit 0
fi
if ! ssd_quirk_present; then
  log "WARN: cmdline usb-storage.quirks=${SSD_USB_VID}:${SSD_USB_PID}:u yok"
elif ! grep -q "usb-storage.quirks=${SSD_USB_VID}:${SSD_USB_PID}:u" /proc/cmdline 2>/dev/null \
  || ! grep -q "usbcore.quirks=${SSD_USB_VID}:${SSD_USB_PID}:k" /proc/cmdline 2>/dev/null \
  || ! grep -q 'usbcore.autosuspend=-1' /proc/cmdline 2>/dev/null; then
  log "WARN: boot cmdline quirks var ama canli kernel'de yok — reboot gerekli"
fi
if ssd_under_voltage; then
  log "WARN: undervolt (vcgencmd get_throttled) — agresif USB port cycle kapali"
fi
run_hotplug() {
  REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/ssd-hotplug-handler.sh"
}
# Gozlem (health-check): USB reset yok — sahip pi-ssd-health.timer
if [[ "$SSD_HEALTH_AUTO" != "true" ]]; then
  if ssd_mount_healthy; then
    ssd_usb_reset_clear
    exit 0
  fi
  log "SSD sagliksiz; SSD_HEALTH_AUTO=false — aksiyon yok"
  exit 1
fi
# Degraded: disk donmus olabilir — poll restore
if storage_degraded; then
  log "degraded — remount/soft-reset poll"
  ssd_usb_learn_live_port 2>/dev/null || true
  ssd_usb_disable_autosuspend || true
  if ssd_try_remount || ssd_usb_soft_reset || ssd_mount_healthy; then
    if ssd_mount_healthy; then
      log "SSD geri — hotplug restore"
      ssd_usb_reset_clear
      if run_hotplug; then
        exit 0
      else
        hp_rc=$?
      fi
      log "HATA: hotplug restore exit $hp_rc — SSD recovery tamamlanmadi"
      exit "$hp_rc"
    fi
  fi
  if ssd_usb_bus_dropout; then
    if ssd_usb_port_reset_rate_limited && ssd_usb_xhci_reset_rate_limited; then
      log "WARN: port+xhci rate-limit — soft-reset beklemede (timer OK)"
    elif ssd_usb_port_reset_rate_limited; then
      log "WARN: port cycle rate-limit — xhci poll devam (timer OK)"
    else
      log "WARN: USB bus dropout — soft-reset yetersiz (timer OK)"
    fi
  else
    log "hala degraded — beklenen FSM (timer OK)"
  fi
  exit 0
fi
# Saglikli gorunuyor mu? USB sysfs poke yok (JMS583 30s poll)
if ssd_mount_healthy; then
  ssd_usb_reset_clear
  if ssd_recent_io_errors; then
    log "WARN: son 15 dk USB/SSD I/O — probe OK, izleniyor"
  fi
  if declare -F ssd_filesystem_needs_fsck >/dev/null 2>&1 && ssd_filesystem_needs_fsck; then
    log "WARN: ext4 fsck gerekli — ssd-fsck.sh --run (veya SSD_FSCK_AUTO=true)"
    if [[ "${SSD_FSCK_AUTO:-false}" == "true" ]] && [[ -x "$SCRIPT_DIR/ssd-fsck.sh" ]]; then
      log "SSD_FSCK_AUTO — fsck baslatiliyor"
      if REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/ssd-fsck.sh" --run; then
        exit 0
      fi
      log "WARN: otomatik fsck basarisiz"
    fi
  fi
  exit 0
fi
ssd_usb_disable_autosuspend || true
# Once block var ama mount yok — once remount (USB reset gereksiz)
if ssd_block_present && ssd_try_remount; then
  log "remount OK — hotplug restore"
  ssd_usb_reset_clear
  if run_hotplug; then
    exit 0
  else
    hp_rc=$?
  fi
  log "HATA: hotplug restore exit $hp_rc"
  exit "$hp_rc"
fi
log "SSD sagliksiz — soft-reset"
if ssd_usb_soft_reset && ssd_mount_healthy; then
  log "soft-reset OK — hotplug restore"
  ssd_usb_reset_clear
  if run_hotplug; then
    exit 0
  else
    hp_rc=$?
  fi
  log "HATA: hotplug restore exit $hp_rc"
  exit "$hp_rc"
fi
log "soft-reset yetersiz — hotplug degraded yolu"
if run_hotplug; then
  hp_rc=0
else
  hp_rc=$?
fi
if ssd_mount_healthy; then
  ssd_usb_reset_clear
  exit 0
fi
if storage_degraded; then
  if ssd_usb_bus_dropout; then
    if ssd_usb_port_reset_rate_limited && ssd_usb_xhci_reset_rate_limited; then
      log "WARN: port+xhci rate-limit — soft-reset beklemede (timer OK)"
    elif ssd_usb_port_reset_rate_limited; then
      log "WARN: port cycle rate-limit — xhci poll devam (timer OK)"
    else
      log "WARN: USB bus dropout — soft-reset yetersiz (timer OK)"
    fi
  else
    log "hala degraded — beklenen FSM (timer OK)"
  fi
  [[ "$hp_rc" -eq 0 ]] && exit 0
  exit "$hp_rc"
fi
METRICS_PY="${REMOTE_DIR}/scripts/lib/ssd-usb-metrics.py"
[[ -f "$METRICS_PY" ]] && python3 "$METRICS_PY" update 2>/dev/null || true
[[ "$hp_rc" -eq 0 ]] && exit 1
exit "$hp_rc"
