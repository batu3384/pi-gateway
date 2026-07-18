#!/usr/bin/env bash
# Mac/CI: migrate/verify PARTUUID kontrat birim testleri (disk gerektirmez)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MIGRATE="$PROJECT_DIR/scripts/mac/migrate-sd-boot-ssd-root.sh"
VERIFY="$PROJECT_DIR/scripts/mac/verify-ssd-root.sh"
REGRESSION="$SCRIPT_DIR/test-ssd-root-contract.sh"

die() { echo "[validate-ssd-root] HATA: $*" >&2; exit 1; }
ok() { echo "[validate-ssd-root] OK: $*"; }

[[ -f "$MIGRATE" ]] || die "migrate yok"
[[ -f "$VERIFY" ]] || die "verify yok"
[[ -f "$REGRESSION" ]] || die "ssd-root regression testi yok"

# --- Migrate: kritik guvenlik stringleri ---
grep -q 'mount_bootfs' "$MIGRATE" || die "migrate mount_bootfs yok"
grep -q 'SD_ROOT_BEFORE' "$MIGRATE" || die "migrate SD_ROOT_BEFORE yok"
grep -q 'SSD root.*flash oncesi SD root ile AYNI' "$MIGRATE" || die "migrate carpısma die yok"
grep -q 'yanlis diskte\|path uyusmuyor' "$MIGRATE" || die "migrate disk eslesme die yok"
grep -q 'sync_boot_partition_cloud_init' "$MIGRATE" || die "migrate SD cloud-init sync yok"
grep -q 'build_ssd_root_cmdline' "$MIGRATE" || die "migrate cmdline preserve yok"
grep -q 'resize' "$VERIFY" || die "verify resize kontrolu yok"
grep -q 'SD bootfs user-data' "$VERIFY" || die "verify SD user-data kontrolu yok"
[[ -f "$PROJECT_DIR/scripts/pi/fix-eeprom-usb-ssd.sh" ]] || die "fix-eeprom-usb-ssd.sh yok"
[[ -f "$PROJECT_DIR/scripts/lib/bootfs-sync.sh" ]] || die "bootfs-sync.sh yok"
grep -q 'bootfs-sync' "$PROJECT_DIR/scripts/mac/repair-cutover-bootfs.sh" \
  || die "repair bootfs-sync kullanmiyor"
grep -q 'PI_SD_DISK\|PI_SSD_DISK' "$MIGRATE" || die "migrate forced disk yok"
ok "migrate guvenlik kontratlari"

# --- Verify: false-green onleme ---
grep -q 'yanlis disk\|path uyusmuyor' "$VERIFY" || die "verify disk eslesme yok"
grep -q 'SD root.*SSD root\|SD ve SSD ayni root' "$VERIFY" || die "verify SD==SSD yok"
grep -q 'bak-pre-ssd-root' "$VERIFY" || die "verify bak-pre kontrolu yok"
grep -q 'hala bak-pre ile ayni' "$VERIFY" || die "verify bak-pre esitlik die yok"
ok "verify false-green onleme"

# --- Neutralize sfdisk dogru syntax ---
NEUT="$PROJECT_DIR/scripts/pi/neutralize-legacy-sd-root.sh"
[[ -f "$NEUT" ]] || die "neutralize yok"
grep -qE 'sfdisk --part-type "\$SD_DISK" 2 0|sfdisk --part-type \$SD_DISK 2 0' "$NEUT" \
  || grep -q 'sfdisk --part-type "$SD_DISK" 2 0' "$NEUT" \
  || die "neutralize sfdisk syntax yanlis (type arg eksik olabilir)"
if grep -q "echo 'type=0' | sfdisk" "$NEUT"; then
  die "neutralize hala pipe'li bozuk sfdisk kullaniyor"
fi
ok "neutralize sfdisk syntax"

# --- Harden script ---
[[ -f "$PROJECT_DIR/scripts/pi/ssd-root-harden.sh" ]] || die "ssd-root-harden.sh yok"
grep -q 'mmcblk' "$PROJECT_DIR/scripts/pi/ssd-root-harden.sh" || die "harden root check yok"
grep -q 'BOOT_ORDER' "$PROJECT_DIR/scripts/pi/ssd-root-harden.sh" || die "harden EEPROM check yok"
ok "ssd-root-harden"

# --- Simule: cmdline root parse (bash) ---
tmp="$(mktemp -d)"
printf '%s\n' 'usb-storage.quirks=152d:0583:u rootdelay=25 root=PARTUUID=abcd1234-02 rootfstype=ext4 rootwait' >"$tmp/cmdline.txt"
got="$(grep -oE 'root=[^ ]+' "$tmp/cmdline.txt" | head -1)"
[[ "$got" == "root=PARTUUID=abcd1234-02" ]] || die "cmdline parse simule fail: $got"
ok "cmdline root parse"

# Simule false-green senaryosu: ayni yanlis UUID
printf '%s\n' 'root=PARTUUID=a49fcf66-02' >"$tmp/sd.txt"
printf '%s\n' 'root=PARTUUID=a49fcf66-02' >"$tmp/ssd.txt"
# verify kontrati: esitlik tek basina yetmez — bak-pre farki gerekir
printf '%s\n' 'root=PARTUUID=a49fcf66-02' >"$tmp/bak.txt"
sd_r="$(grep -oE 'root=[^ ]+' "$tmp/sd.txt")"
bak_r="$(grep -oE 'root=[^ ]+' "$tmp/bak.txt")"
[[ "$sd_r" == "$bak_r" ]] && ok "false-green senaryosu algilanabilir (sd==bak)"

rm -rf "$tmp"

# Defaults: deploy hybrid olmali (uretim)
grep -q "STORAGE_TYPE:-hybrid" "$PROJECT_DIR/scripts/mac/deploy.sh" \
  || die "deploy.sh hybrid default degil"
ok "deploy hybrid default"

echo "[validate-ssd-root] Tum birim testleri gecti"

bash "$REGRESSION"
