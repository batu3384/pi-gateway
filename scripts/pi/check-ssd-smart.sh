#!/usr/bin/env bash
# SSD SMART / wear check (hybrid data disk). Warn via journal + optional notify.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="pi-gateway-ssd-smart"
SSD_WEAR_WARN_PCT="${SSD_WEAR_WARN_PCT:-90}"
SSD_REALLOC_WARN="${SSD_REALLOC_WARN:-10}"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[ssd-smart] HATA: .env dotenv parser hatasi" >&2; exit 1; }
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

log() {
  logger -t "$LOG_TAG" "$*"
  echo "[ssd-smart] $*"
}

if is_ssd_root_mode || ! needs_ssd_storage; then
  log "SSD data disk yok — atlaniyor"
  exit 0
fi

if ! command -v smartctl >/dev/null 2>&1; then
  log "smartctl yok — apt install smartmontools"
  exit 0
fi

ssd_dev=""
if mountpoint -q /mnt/ssd 2>/dev/null; then
  src="$(findmnt -n -o SOURCE /mnt/ssd 2>/dev/null || true)"
  if [[ -n "$src" && -b "$src" ]]; then
    ssd_dev="$src"
    ssd_dev="${ssd_dev%/}" # sda1 -> keep partition for NVMe/SATA
    if [[ "$ssd_dev" =~ ^/dev/(sd[a-z]|nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
      ssd_dev="$(echo "$ssd_dev" | sed -E 's/p?[0-9]+$//')"
      [[ -b "${ssd_dev}" ]] || ssd_dev="$(findmnt -n -o SOURCE /mnt/ssd)"
    fi
  fi
fi
if [[ -z "$ssd_dev" ]]; then
  ssd_dev="$(blkid -L "${SSD_LABEL:-pi-data}" 2>/dev/null || true)"
fi
[[ -n "$ssd_dev" && -b "$ssd_dev" ]] || {
  log "SSD block bulunamadi — atlaniyor"
  exit 0
}

run_smart() {
  if [[ "$(id -u)" -eq 0 ]]; then
    smartctl -H -d auto "$ssd_dev" 2>/dev/null
    smartctl -A -d auto "$ssd_dev" 2>/dev/null || true
  else
    sudo smartctl -H -d auto "$ssd_dev" 2>/dev/null
    sudo smartctl -A -d auto "$ssd_dev" 2>/dev/null || true
  fi
}

health_out="$(run_smart 2>/dev/null || true)"
if ! echo "$health_out" | grep -qiE 'PASSED|OK'; then
  log "WARN: SMART health FAIL veya okunamadi ($ssd_dev)"
  # shellcheck source=../lib/notify.sh
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_disk_warn "/mnt/ssd" "SMART health FAIL ($ssd_dev)"
  exit 1
fi

wear_pct=""
if echo "$health_out" | grep -qi nvme; then
  wear_pct="$(echo "$health_out" | awk -F: '/Percentage Used/{gsub(/[^0-9]/,"",$2); print $2; exit}')"
elif echo "$health_out" | grep -qi 'Wear_Leveling_Count\|Media_Wearout_Indicator'; then
  wear_pct="$(echo "$health_out" | awk -F: '/Wear_Leveling_Count|Media_Wearout_Indicator/{gsub(/[^0-9]/,"",$2); v=$2; exit} END{print v}')"
  if [[ -n "$wear_pct" && "$wear_pct" =~ ^[0-9]+$ && "$wear_pct" -le 100 ]]; then
    wear_pct=$((100 - wear_pct))
  fi
fi
realloc="$(echo "$health_out" | awk -F: '/Reallocated_Sector_Ct/{gsub(/[^0-9]/,"",$2); print $2; exit}')"

if [[ -n "$wear_pct" && "$wear_pct" =~ ^[0-9]+$ ]] && (( wear_pct >= SSD_WEAR_WARN_PCT )); then
  log "WARN: SSD wear ${wear_pct}% >= ${SSD_WEAR_WARN_PCT}%"
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_disk_warn "/mnt/ssd" "wear ${wear_pct}%"
fi
if [[ -n "$realloc" && "$realloc" =~ ^[0-9]+$ ]] && (( realloc >= SSD_REALLOC_WARN )); then
  log "WARN: reallocated sectors ${realloc} >= ${SSD_REALLOC_WARN}"
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_disk_warn "/mnt/ssd" "realloc ${realloc}"
fi

log "OK SMART $ssd_dev (wear=${wear_pct:-n/a} realloc=${realloc:-n/a})"
exit 0
