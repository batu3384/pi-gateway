#!/usr/bin/env bash
# SSD-root regression tests. No real disks required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "[test-ssd-root] HATA: $*" >&2; exit 1; }
ok() { echo "[test-ssd-root] OK: $*"; }

source "$PROJECT_DIR/scripts/lib/mbr-partuuid.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

raw="$tmp/disk.img"
dd if=/dev/zero of="$raw" bs=512 count=1 >/dev/null 2>&1
printf '\x78\xe3\xf6\x36' | dd of="$raw" bs=1 seek=440 conv=notrunc >/dev/null 2>&1

got="$(mbr_partuuid_from_raw_file "$raw" 2)"
[[ "$got" == "36f6e378-02" ]] || die "MBR PARTUUID parse: $got"
ok "MBR PARTUUID parse"

grep -q 'BOOT_ORDER="0xf41"' "$PROJECT_DIR/scripts/pi/fix-eeprom-usb-ssd.sh" \
  || die "A mimarisi SD-first BOOT_ORDER yanlis"
ok "A mimarisi SD-first EEPROM order"

grep -q 'USB_MSD_DISCOVER_TIMEOUT=25000' "$PROJECT_DIR/scripts/pi/fix-eeprom-usb-ssd.sh" \
  || die "USB_MSD_DISCOVER_TIMEOUT kontrati eksik"
ok "EEPROM USB timeout"

grep -q -- '--disable-verify' "$PROJECT_DIR/scripts/mac/migrate-sd-boot-ssd-root.sh" \
  && die "migrate yazma dogrulamasini varsayilan olarak kapatiyor"
ok "Imager verify varsayilan acik"

grep -q 'rsync -a' "$PROJECT_DIR/scripts/mac/migrate-sd-boot-ssd-root.sh" \
  || die "migrate SSD boot firmware/kernel sync yok"
grep -q 'ayni mount path' "$PROJECT_DIR/scripts/mac/migrate-sd-boot-ssd-root.sh" \
  || die "migrate mount alias korumasi yok"
ok "SSD boot firmware/kernel sync + mount alias korumasi"

grep -qE 'verify_pi4_boot_archives|gzip -t' "$PROJECT_DIR/scripts/mac/verify-ssd-root.sh" \
  || die "verify kernel archive integrity yok"
grep -q 'VERIFY_STRICT_SSD_BOOTFS\|STRICT_SSD_BOOTFS' "$PROJECT_DIR/scripts/mac/verify-ssd-root.sh" \
  || die "verify SSD bootfs strict modu yok"
ok "Pi 4 kernel/initramfs integrity + SSD strict/warn modu"

echo "[test-ssd-root] Tum regresyon testleri gecti"
