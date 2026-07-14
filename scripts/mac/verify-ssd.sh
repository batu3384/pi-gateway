#!/usr/bin/env bash
# Mac'te Pi SSD tanilama (yazmadan once/sonra)
set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }

[[ "$(uname)" == "Darwin" ]] || { echo "Sadece macOS"; exit 1; }

find_pi_ssd() {
  local disk info size name
  while read -r disk; do
    [[ -z "$disk" ]] && continue
    info=$(diskutil info "$disk" 2>/dev/null) || continue
    echo "$info" | grep -q "Internal" && continue
    size=$(echo "$info" | awk -F': *' '/Disk Size/ {print $2}' | head -1)
    echo "$size" | grep -qE "T|1000" && continue
    if diskutil list "$disk" 2>/dev/null | grep -qE "bootfs|Linux"; then
      echo "$disk"
      return 0
    fi
    name=$(echo "$info" | awk -F': *' '/Device \/ Media Name/ {print $2}' | head -1)
    echo "$name" | grep -qiE "yongzhen|samsung|ssd" && { echo "$disk"; return 0; }
  done < <(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+ \(external/ {print $1}' | tr -d ':')
  return 1
}

DISK=$(find_pi_ssd) || { log "Pi SSD bulunamadi"; exit 1; }
RDISK="/dev/r${DISK#/dev/}"

INFO=$(diskutil info "$DISK")
NAME=$(echo "$INFO" | awk -F': *' '/Device \/ Media Name/ {print $2}' | head -1)
SIZE=$(echo "$INFO" | awk -F': *' '/Disk Size/ {print $2}' | head -1)

log "=== Pi SSD Raporu ==="
log "Disk: $DISK ($RDISK)"
log "Adaptor: $NAME"
log "Boyut: $SIZE"
echo ""
diskutil list "$DISK"
echo ""

# Boot partition
BOOT=""
if [[ -d /Volumes/bootfs ]]; then
  BOOT="/Volumes/bootfs"
elif diskutil mount "${DISK}s1" >/dev/null 2>&1; then
  sleep 1
  [[ -d /Volumes/bootfs ]] && BOOT="/Volumes/bootfs"
fi

if [[ -n "$BOOT" ]]; then
  log "--- Boot partition ---"
  log "OS: $(cat "$BOOT/issue.txt" 2>/dev/null || echo '?')"
  log "cmdline: $(cat "$BOOT/cmdline.txt" 2>/dev/null || echo '?')"

  for f in kernel8.img start4.elf initramfs8; do
    [[ -f "$BOOT/$f" ]] && log "OK $f" || log "EKSIK $f"
  done

  log "--- Ilk kurulum ---"
  [[ -f "$BOOT/user-data" ]] && log "user-data: var" || log "user-data: YOK"
  [[ -f "$BOOT/network-config" ]] && log "network-config: var" || log "network-config: YOK"
  [[ -f "$BOOT/ssh" ]] && log "ssh (legacy): var" || log "ssh (legacy): yok"
  [[ -f "$BOOT/userconf" ]] && log "userconf (legacy): var" || log "userconf (legacy): yok"

  if [[ -f "$BOOT/user-data" ]]; then
    if grep -qE '^hostname:' "$BOOT/user-data" 2>/dev/null; then
      log "cloud-init hostname: $(grep '^hostname:' "$BOOT/user-data")"
    else
      log "UYARI: cloud-init hostname AYARLI DEGIL (varsayilan kullanici olabilir)"
    fi
    if grep -qE '^enable_ssh:' "$BOOT/user-data" 2>/dev/null; then
      log "cloud-init SSH: $(grep '^enable_ssh:' "$BOOT/user-data")"
    else
      log "UYARI: cloud-init enable_ssh AYARLI DEGIL"
    fi
    if grep -qE "^\s+- name: " "$BOOT/user-data" 2>/dev/null; then
      log "cloud-init kullanici: $(grep -E '^\s+- name:' "$BOOT/user-data" | head -1)"
    else
      log "UYARI: cloud-init kullanici TANIMLI DEGIL"
    fi
  fi
  grep -q "usb-storage.quirks=" "$BOOT/cmdline.txt" 2>/dev/null && log "USB quirks: $(grep -o 'usb-storage.quirks=[^ ]*' "$BOOT/cmdline.txt")" || log "UYARI: USB quirks YOK (Pi boot riski)"
  grep -q "boot_delay=" "$BOOT/config.txt" 2>/dev/null && log "boot_delay: OK" || log "UYARI: boot_delay YOK"

  LINUX_SIZE=$(diskutil list "$DISK" | awk '/Linux/ {print $3,$4}' | head -1)
  FREE=$(diskutil list "$DISK" | awk '/free space/ {print $3,$4}' | head -1)
  log "--- Partition ---"
  log "Linux partition: ${LINUX_SIZE:-?}"
  if [[ -n "$FREE" ]]; then
    log "Bos alan: $FREE (normal — ilk acilista 'resize' genisletir)"
  fi
else
  log "bootfs mount edilemedi"
fi

echo ""
log "--- Okuma testi (sudo gerekir) ---"
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  if dd if="$RDISK" of=/dev/null bs=1m count=2048 2>/tmp/verify-ssd-dd.err; then
    log "2GB okuma testi: OK"
  else
    log "2GB okuma testi: BASARISIZ"
    cat /tmp/verify-ssd-dd.err
  fi
else
  log "Tam test icin: sudo $0"
fi
