#!/usr/bin/env bash
# SD kart bootfs uzerinden Pi sifresini sifirla (Mac)
set -euo pipefail

PI_USER="${PI_USER:-pi}"
NEW_PASSWORD="${NEW_PASSWORD:-}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "HATA: $*"; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "Sadece macOS"

find_sd_disk() {
  local disk gb
  while read -r disk; do
    [[ -z "$disk" ]] && continue
    diskutil info "$disk" 2>/dev/null | grep -q "Internal" && continue
    gb=$(diskutil info "$disk" 2>/dev/null | awk -F': *' '/Disk Size/ {print $2}' | grep -oE '[0-9]+' | head -1)
    [[ -n "$gb" && "$gb" -ge 28 && "$gb" -le 40 ]] || continue
    diskutil list "$disk" 2>/dev/null | grep -q bootfs && { echo "$disk"; return 0; }
  done < <(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+ \(external/ {print $1}' | tr -d ':')
  return 1
}

SD=$(find_sd_disk) || die "SD kart bulunamadi (~32GB). Pi'den cikarip Mac'e tak."

diskutil mount "${SD}s1" >/dev/null 2>&1 || true
BOOT=""
for vol in /Volumes/bootfs "/Volumes/bootfs 1"; do
  [[ -d "$vol/cmdline.txt" || -f "$vol/cmdline.txt" ]] && BOOT="$vol" && break
done
[[ -n "$BOOT" ]] || die "bootfs mount edilemedi"

if [[ -z "$NEW_PASSWORD" ]]; then
  read -r -s -p "Yeni Pi sifresi ($PI_USER, min 8): " NEW_PASSWORD
  echo
fi
[[ ${#NEW_PASSWORD} -ge 8 ]] || die "Sifre min 8 karakter"

HASH=$(echo -n "$NEW_PASSWORD" | openssl passwd -6 -stdin)
echo "${PI_USER}:${HASH}" > "$BOOT/userconf"

# cloud-init user-data guncelle (varsa)
if [[ -f "$BOOT/user-data" ]]; then
  if grep -q 'plain_text_password:' "$BOOT/user-data"; then
    sed -i '' -E "s|^[[:space:]]*plain_text_password:.*$|    passwd: '$HASH'|" "$BOOT/user-data"
    log "user-data: acik parola hash'e cevrildi"
  elif grep -q '^[[:space:]]*passwd:' "$BOOT/user-data"; then
    sed -i '' -E "s|^[[:space:]]*passwd:.*$|    passwd: '$HASH'|" "$BOOT/user-data"
    log "user-data: hash guncellendi"
  else
    log "WARN: user-data passwd alani yok (atlandi)"
  fi
fi

# init=/bin/bash ile tek seferlik sifre sifirlama (userconf yetmezse)
CMDLINE="$BOOT/cmdline.txt"
LINE=$(tr -d '\n' < "$CMDLINE")
LINE=$(echo "$LINE" | sed -E 's| init=/bin/bash||g; s| init=/bin/sh||g')
echo "${LINE} init=/bin/bash" > "$CMDLINE"

sync
log "=== Yapildi ==="
log "1. userconf guncellendi"
log "2. cmdline.txt -> init=/bin/bash eklendi (tek acilis)"
log ""
log "Pi'de:"
log "  - SD tak, ac"
log "  - Siyah ekran/terminal gelirse Enter"
log "  - Su komutlari yaz:"
log "      mount -o remount,rw /"
log "      passwd ${PI_USER}"
log "      sed -i 's| init=/bin/bash||' /boot/firmware/cmdline.txt 2>/dev/null || sed -i 's| init=/bin/bash||' /boot/cmdline.txt"
log "      sync && reboot -f"
log ""
log "Alternatif: init shell acilmazsa sadece userconf ile tekrar dene (ilk boot gibi)"
diskutil unmount "$BOOT" >/dev/null 2>&1 || true
