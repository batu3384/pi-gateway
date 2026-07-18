#!/usr/bin/env bash
# Mac: cutover bootfs onarimi — SD golden (A mimarisi: Pi SD bootfs'ten acilir)
# - SD firmware/kernel/initramfs dogrulanir
# - cmdline + cloud-init hizalanir
# - SSD bootfs'e best-effort sync (JMicron okuyucuda bozulabilir)
#
# Kullanim: PI_SD_DISK=/dev/disk47 PI_SSD_DISK=/dev/disk46 ./scripts/mac/repair-cutover-bootfs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/usb-quirk.sh
source "$SCRIPT_DIR/../lib/usb-quirk.sh"
# shellcheck source=../lib/ssd-root-cmdline.sh
source "$SCRIPT_DIR/../lib/ssd-root-cmdline.sh"
# shellcheck source=../lib/bootfs-sync.sh
source "$SCRIPT_DIR/../lib/bootfs-sync.sh"

log() { echo "[repair-cutover] $*"; }
die() { log "HATA: $*"; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "Sadece macOS"

PI_SD_DISK="${PI_SD_DISK:-}"
PI_SSD_DISK="${PI_SSD_DISK:-}"
STRICT_SSD_BOOTFS="${STRICT_SSD_BOOTFS:-no}"

if [[ -z "$PI_SD_DISK" || -z "$PI_SSD_DISK" ]]; then
  die "PI_SD_DISK ve PI_SSD_DISK zorunlu"
fi

validate_disk() {
  local label="$1" disk="$2" min_gb="$3" max_gb="$4" info gb
  [[ "$disk" =~ ^/dev/disk[0-9]+$ ]] || die "$label whole disk yolu gecersiz: $disk"
  info="$(diskutil info "$disk" 2>/dev/null)" || die "$label diskutil info basarisiz: $disk"
  echo "$info" | grep -qE '^   Whole: +Yes$' || die "$label whole disk degil: $disk"
  echo "$info" | grep -qE '^   Device Location: +External$' || die "$label external disk degil: $disk"
  echo "$info" | grep -qE '^   Media Read-Only: +No$' || die "$label disk salt-okunur: $disk"
  gb="$(echo "$info" | awk -F': *' '/Disk Size/ {print $2}' | grep -oE '[0-9]+' | head -1)"
  [[ -n "$gb" && "$gb" -ge "$min_gb" && "$gb" -le "$max_gb" ]] || die "$label boyutu gecersiz: ${gb:-?}GB"
}

[[ "$PI_SD_DISK" != "$PI_SSD_DISK" ]] || die "SD ve SSD ayni disk"
validate_disk SD "$PI_SD_DISK" 8 512
validate_disk SSD "$PI_SSD_DISK" 32 4096

mount_bootfs() {
  local part="${1}s1" mp
  diskutil mount "$part" >/dev/null 2>&1 || true
  sleep 1
  mp="$(diskutil info "$part" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2; exit}')"
  [[ -n "$mp" && "$mp" != "Not applicable" && -f "$mp/cmdline.txt" ]] || return 1
  echo "$mp"
}

BOOT_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pi-sd-boot-repair.XXXXXX")"
trap 'rm -rf "$BOOT_STAGE"' EXIT

BOOT_SD="$(mount_bootfs "$PI_SD_DISK")" || die "SD bootfs mount edilemedi"
BOOT_SSD="$(mount_bootfs "$PI_SSD_DISK")" || die "SSD bootfs mount edilemedi"
[[ "$BOOT_SD" != "$BOOT_SSD" ]] || die "SD ve SSD ayni mount path — kaynak/hedef karisikligi"

verify_pi4_boot_archives "$BOOT_SD" || die "SD boot archive bozuk — once SD bootfs onarilmali"

sanitize_cloud_init() {
  local boot="$1" hash
  [[ -f "$boot/user-data" && -f "$boot/userconf" ]] || die "cloud-init eksik: $boot"
  hash="$(awk -F: 'NR == 1 {print $2; exit}' "$boot/userconf")"
  case "$hash" in
    '$1$'*|'$5$'*|'$6$'*) ;;
    *) die "userconf hash gecersiz: $boot" ;;
  esac
  if grep -q 'plain_text_password:' "$boot/user-data"; then
    sed -i '' -E "s|^[[:space:]]*plain_text_password:.*$|    passwd: '$hash'|" "$boot/user-data"
    log "Acik cloud-init parolasi hash'e cevrildi: $boot"
  fi
  grep -q '^[[:space:]]*passwd:' "$boot/user-data" || die "cloud-init passwd alani yok: $boot"
}

sanitize_cloud_init "$BOOT_SD"

# SD golden snapshot
bootfs_snapshot_from_volume "$BOOT_SD" "$BOOT_STAGE" || \
  die "SD bootfs snapshot checksum basarisiz — SD okuyucu/USB kararsiz"
log "SD golden snapshot OK"

# SSD'ye firmware/kernel sync (best-effort; A mimarisinde boot SD'den)
if bootfs_apply_snapshot "$BOOT_STAGE" "$BOOT_SSD"; then
  log "SSD bootfs snapshot yazildi"
  sync
  diskutil unmountDisk force "$PI_SSD_DISK" >/dev/null 2>&1 || true
  diskutil mount "${PI_SSD_DISK}s1" >/dev/null 2>&1 || true
  sleep 2
  BOOT_SSD="$(mount_bootfs "$PI_SSD_DISK")" || die "SSD remount basarisiz"
  if bootfs_rsync_checksum_ok "$BOOT_STAGE" "$BOOT_SSD"; then
    log "SSD bootfs remount checksum OK"
  else
    log "WARN: SSD bootfs remount sonrasi checksum farkli — JMicron okuyucu suphesi"
  fi
else
  log "WARN: SSD bootfs yazma checksum basarisiz — Pi yine de SD bootfs ile acilabilir"
fi

# SD cmdline + cloud-init
[[ -f "$BOOT_SD/cmdline.txt.bak-pre-ssd-root" ]] || \
  die "SD rollback backup yok — bilinmeyen root'u backup diye kaydetmiyorum"

QUIRK="$(detect_usb_quirk)"
SSD_LINE="$(tr -d '\n' < "$BOOT_SSD/cmdline.txt")"
NEW_CMD="$(build_ssd_root_cmdline "$QUIRK" "$SSD_LINE")"
cmdline_has_resize "$NEW_CMD" || log "WARN: cmdline resize yok"

printf '%s\n' "$NEW_CMD" > "$BOOT_SD/cmdline.txt"
printf '%s\n' "$NEW_CMD" > "$BOOT_SSD/cmdline.txt"
log "cmdline SD+SSD hizalandi"

sync_boot_partition_cloud_init "$BOOT_SD" "$BOOT_SD" 2>/dev/null || true
for f in user-data network-config userconf ssh; do
  cp "$BOOT_SD/$f" "$BOOT_SSD/$f" 2>/dev/null || cp "$BOOT_STAGE/$f" "$BOOT_SSD/$f" 2>/dev/null || true
  [[ -f "$BOOT_SSD/ssh" ]] || touch "$BOOT_SSD/ssh"
done

for kv in boot_delay=5 usb_max_current_enable=1 hdmi_force_hotplug=1; do
  key="${kv%%=*}"
  cfg="$BOOT_SD/config.txt"
  if grep -q "^${key}=" "$cfg" 2>/dev/null; then
    sed -i '' "s|^${key}=.*|${kv}|" "$cfg"
  else
    echo "$kv" >>"$cfg"
  fi
done
cp "$BOOT_SD/config.txt" "$BOOT_SSD/config.txt"

sync

# Verify: SD zorunlu; SSD bootfs A mimarisinde ikincil
VERIFY_STRICT_SSD_BOOTFS="$STRICT_SSD_BOOTFS" \
  PI_SD_DISK="$PI_SD_DISK" PI_SSD_DISK="$PI_SSD_DISK" \
  bash "$SCRIPT_DIR/verify-ssd-root.sh" || {
    if [[ "$STRICT_SSD_BOOTFS" == "yes" ]]; then
      die "verify basarisiz (STRICT_SSD_BOOTFS=yes)"
    fi
    log "WARN: verify kismi basarisiz — SD bootfs gecerliyse Pi acilabilir"
  }

log "Onarim tamam — SD+SSD Pi'ye tak, Ethernet, 5-10 dk bekle"
