#!/usr/bin/env bash
# Mac: Gecici SD root boot (EEPROM/SSD sorunlarinda Pi'yi online etmek icin)
# Sonra: repair-cutover-bootfs.sh ile SSD root'a geri don
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/mbr-partuuid.sh
source "$SCRIPT_DIR/../lib/mbr-partuuid.sh"

PI_SD_DISK="${PI_SD_DISK:-}"
[[ -n "$PI_SD_DISK" ]] || { echo "PI_SD_DISK=/dev/diskXX gerekli" >&2; exit 1; }
[[ "$(uname)" == "Darwin" ]] || { echo "Sadece macOS" >&2; exit 1; }

[[ "$PI_SD_DISK" =~ ^/dev/disk[0-9]+$ ]] || { echo "whole disk yolu bekleniyor: $PI_SD_DISK" >&2; exit 1; }
diskutil info "$PI_SD_DISK" 2>/dev/null | grep -qE '^   Whole: +Yes$' || { echo "whole disk degil: $PI_SD_DISK" >&2; exit 1; }
diskutil info "$PI_SD_DISK" 2>/dev/null | grep -qE '^   Device Location: +External$' || { echo "external SD degil: $PI_SD_DISK" >&2; exit 1; }
diskutil info "$PI_SD_DISK" 2>/dev/null | grep -qE '^   Media Read-Only: +No$' || { echo "SD salt-okunur: $PI_SD_DISK" >&2; exit 1; }
part="${PI_SD_DISK}s1"
diskutil mount "$part" >/dev/null 2>&1 || true
mp="$(diskutil info "$part" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2; exit}')"
[[ -f "$mp/cmdline.txt" ]] || { echo "bootfs yok: $mp" >&2; exit 1; }

bak="$mp/cmdline.txt.bak-pre-ssd-root"
[[ -f "$bak" ]] || { echo "bak-pre yok — elle root=PARTUUID=a49fcf66-02 yaz" >&2; exit 1; }

old_root="$(grep -oE 'root=[^ ]+' "$bak" | head -1 || true)"
[[ "$old_root" == root=PARTUUID=* ]] || { echo "rollback backup root gecersiz: $old_root" >&2; exit 1; }
current_root="$(grep -oE 'root=[^ ]+' "$mp/cmdline.txt" | head -1 || true)"
[[ "$current_root" != "$old_root" ]] || { echo "SD zaten rollback root'ta: $old_root" >&2; exit 1; }

cp "$mp/cmdline.txt" "$mp/cmdline.txt.bak-ssd-root-rollback"
cp "$bak" "$mp/cmdline.txt"
sync
echo "[rollback-sd-root] SD cmdline eski root'a alindi:"
grep -oE 'root=[^ ]+' "$mp/cmdline.txt"
echo "Pi'ye SADECE SD takip ac (veya SSD takili kalabilir ama root SD'den)."
echo "Online olunca: CONFIRM_EEPROM_FIX=yes fix-eeprom-usb-ssd.sh"
echo "Sonra: repair-cutover-bootfs.sh ile SSD root'a don"
