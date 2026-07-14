#!/usr/bin/env bash
# SSD boot partition: Pi USB adaptör uyumluluk düzeltmeleri (yeniden flash gerekmez)
set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "HATA: $*"; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "Sadece macOS"

find_pi_ssd() {
  local disk info size
  while read -r disk; do
    [[ -z "$disk" ]] && continue
    info=$(diskutil info "$disk" 2>/dev/null) || continue
    echo "$info" | grep -q "Internal" && continue
    size=$(echo "$info" | awk -F': *' '/Disk Size/ {print $2}' | head -1)
    echo "$size" | grep -qE "T|1000" && continue
    diskutil list "$disk" 2>/dev/null | grep -qE "bootfs|Linux" && { echo "$disk"; return 0; }
  done < <(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+ \(external/ {print $1}' | tr -d ':')
  return 1
}

detect_usb_quirk() {
  # YongzhenWeiye / jack88888 / YzWy — JMicron ailesi
  local vid pid
  vid=$(ioreg -l 2>/dev/null | grep -A30 "YzWy  Disk Device" | grep '"idVendor"' | head -1 | sed 's/.*= //')
  pid=$(ioreg -l 2>/dev/null | grep -A30 "YzWy  Disk Device" | grep '"idProduct"' | head -1 | sed 's/.*= //')
  if [[ -n "$vid" && -n "$pid" ]]; then
    printf "%04x:%04x:u" "$vid" "$pid"
    return 0
  fi
  if ioreg -l 2>/dev/null | grep -q "YongzhenWeiye"; then
    echo "152d:0583:u"
    return 0
  fi
  return 1
}

DISK=$(find_pi_ssd) || die "Pi SSD bulunamadi"
QUIRK=$(detect_usb_quirk) || QUIRK="152d:0583:u"

diskutil mount "${DISK}s1" >/dev/null 2>&1 || true
[[ -d /Volumes/bootfs ]] || die "bootfs mount edilemedi"

BOOT="/Volumes/bootfs"
CMDLINE="$BOOT/cmdline.txt"
CONFIG="$BOOT/config.txt"

log "SSD: $DISK"
log "USB quirk: $QUIRK"

# cmdline.txt — UAS kapat (Pi uyumluluk)
if grep -q "usb-storage.quirks=" "$CMDLINE" 2>/dev/null; then
  sed -i '' "s|usb-storage.quirks=[^ ]*|usb-storage.quirks=${QUIRK}|" "$CMDLINE"
  log "cmdline quirks guncellendi"
else
  sed -i '' "1s|^|usb-storage.quirks=${QUIRK} |" "$CMDLINE"
  log "cmdline quirks eklendi"
fi

# config.txt — guc + boot gecikmesi
grep -q "^boot_delay=" "$CONFIG" 2>/dev/null || echo "boot_delay=5" >> "$CONFIG"
grep -q "^usb_max_current_enable=" "$CONFIG" 2>/dev/null || echo "usb_max_current_enable=1" >> "$CONFIG"
log "config.txt: boot_delay=5, usb_max_current_enable=1"

sync
log "cmdline: $(cat "$CMDLINE")"
log "=== Duzeltme tamam ==="
log "SSD'yi cikar, Pi'de dene (SD cikik, HDMI 0, 3A guc)"
