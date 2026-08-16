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
  log "WARN: undervolt (vcgencmd get_throttled)"
fi
run_hotplug() {
  REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/ssd-hotplug-handler.sh"
}
# Gozlem (health-check): USB reset yok — sahip pi-ssd-health.timer
if [[ "$SSD_HEALTH_AUTO" != "true" ]]; then
  if ssd_mount_healthy; then
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
      run_hotplug
      exit 0
    fi
  fi
  log "hala degraded — beklenen FSM (timer OK)"
  exit 0
fi
# Saglikli gorunuyor mu? USB sysfs poke yok (JMS583 30s poll)
if ssd_mount_healthy; then
  if ssd_recent_io_errors; then
    log "WARN: son 15 dk USB/SSD I/O — probe OK, izleniyor"
  fi
  exit 0
fi
ssd_usb_disable_autosuspend || true
# Once block var ama mount yok — once remount (USB reset gereksiz)
if ssd_block_present && ssd_try_remount; then
  log "remount OK — hotplug restore"
  run_hotplug
  exit 0
fi
log "SSD sagliksiz — soft-reset"
if ssd_usb_soft_reset && ssd_mount_healthy; then
  log "soft-reset OK — hotplug restore"
  run_hotplug
  exit 0
fi
log "soft-reset yetersiz — hotplug degraded yolu"
run_hotplug
if ssd_mount_healthy; then
  exit 0
fi
if storage_degraded; then
  log "hala degraded — beklenen FSM (timer OK)"
  exit 0
fi
exit 1
