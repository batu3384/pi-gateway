#!/usr/bin/env bash
# Mac: SD root + SSD veri (hybrid) — ssd-root cutover sonrasi geri donus
#
# Yapar:
#   - SD cmdline -> SD root (PARTUUID diskten okunur)
#   - SD boot firmware/kernel <- golden snapshot (cmdline/cloud-init haric)
#   - user-data: pi-setup-ssd-data + pi-ssd-data.service
#   - JMicron quirks; rootdelay/resize kaldirilir
#   - SSD disk sifirlanir (Pi ext4 olusturur)
#
# Kullanim:
#   PI_SD_DISK=/dev/disk47 PI_SSD_DISK=/dev/disk46 CONFIRM_WIPE_SSD=yes ./scripts/mac/restore-hybrid-boot.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/usb-quirk.sh
source "$SCRIPT_DIR/../lib/usb-quirk.sh"
# shellcheck source=../lib/bootfs-sync.sh
source "$SCRIPT_DIR/../lib/bootfs-sync.sh"
# shellcheck source=../lib/mbr-partuuid.sh
source "$SCRIPT_DIR/../lib/mbr-partuuid.sh"
# shellcheck source=../lib/hybrid-cloud-init.sh
source "$SCRIPT_DIR/../lib/hybrid-cloud-init.sh"

log() { echo "[restore-hybrid] $*"; }
die() { log "HATA: $*"; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "Sadece macOS"

PI_SD_DISK="${PI_SD_DISK:-}"
PI_SSD_DISK="${PI_SSD_DISK:-}"
CONFIRM_WIPE_SSD="${CONFIRM_WIPE_SSD:-}"
SD_ROOT_PARTUUID="${SD_ROOT_PARTUUID:-}"

[[ -n "$PI_SD_DISK" && -n "$PI_SSD_DISK" ]] || die "PI_SD_DISK ve PI_SSD_DISK zorunlu"
[[ "$PI_SD_DISK" != "$PI_SSD_DISK" ]] || die "SD ve SSD ayni disk"

validate_disk() {
  local label="$1" disk="$2" min_gb="$3" max_gb="$4" info gb
  [[ "$disk" =~ ^/dev/disk[0-9]+$ ]] || die "$label: whole disk gerekli: $disk"
  info="$(diskutil info "$disk" 2>/dev/null)" || die "$label diskutil fail: $disk"
  echo "$info" | grep -qE '^   Whole: +Yes$' || die "$label whole disk degil"
  echo "$info" | grep -qE '^   Device Location: +External$' || die "$label external degil"
  gb="$(echo "$info" | awk -F': *' '/Disk Size/ {print $2}' | grep -oE '[0-9]+' | head -1)"
  [[ -n "$gb" && "$gb" -ge "$min_gb" && "$gb" -le "$max_gb" ]] || die "$label boyut gecersiz: ${gb:-?}GB"
}

validate_disk SD "$PI_SD_DISK" 8 512
validate_disk SSD "$PI_SSD_DISK" 32 4096

mount_bootfs() {
  local disk="$1" part mp
  part="${disk}s1"
  diskutil mount "$part" >/dev/null 2>&1 || true
  sleep 1
  mp="$(diskutil info "$part" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2; exit}')"
  [[ -n "$mp" && "$mp" != "Not applicable" && -f "$mp/cmdline.txt" ]] || return 1
  echo "$mp"
}

copy_bootfs_file_if_missing() {
  local name="$1" sd="$2" ssd="$3"
  if [[ -f "${sd}/${name}" ]]; then
    return 0
  fi
  if [[ -n "$ssd" && "$ssd" != "$sd" && -f "${ssd}/${name}" ]]; then
    cp "${ssd}/${name}" "${sd}/${name}"
  fi
}

BOOT_SD="$(mount_bootfs "$PI_SD_DISK")" || die "SD bootfs mount edilemedi"

SD_ROOT_PARTUUID="$(detect_sd_root_partuuid "$PI_SD_DISK" "$BOOT_SD" "${SD_ROOT_PARTUUID:-}")" \
  || die "SD root PARTUUID okunamadi — SD_ROOT_PARTUUID=xx-xx belirt"
log "SD root PARTUUID: ${SD_ROOT_PARTUUID}"

BOOT_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pi-hybrid-restore.XXXXXX")"
trap 'rm -rf "$BOOT_STAGE"' EXIT

BOOT_SSD=""
if mp_ssd="$(mount_bootfs "$PI_SSD_DISK" 2>/dev/null)"; then
  BOOT_SSD="$mp_ssd"
fi
if [[ -z "$BOOT_SSD" ]]; then
  if [[ "$CONFIRM_WIPE_SSD" == "yes" ]]; then
    log "SSD bootfs yok (bos disk) — yalnizca SD guncelleniyor"
    BOOT_SSD=""
  else
    die "SSD bootfs mount edilemedi — disk bos ise CONFIRM_WIPE_SSD=yes"
  fi
elif [[ "$BOOT_SSD" == "$BOOT_SD" ]]; then
  die "SD ve SSD ayni mount path — disk numaralarini kontrol et"
fi

# Golden kaynak: SSD bootfs (kernel saglam); SSD bos ise SD
GOLDEN=""
if [[ -n "$BOOT_SSD" ]] && verify_pi4_boot_archives "$BOOT_SSD"; then
  GOLDEN="$BOOT_SSD"
elif verify_pi4_boot_archives "$BOOT_SD"; then
  GOLDEN="$BOOT_SD"
  [[ -n "$BOOT_SSD" ]] && log "SSD kernel bozuk — SD golden kullaniliyor"
else
  die "Hem SD hem SSD kernel bozuk — setup-hybrid.sh veya Imager gerekli"
fi

bootfs_snapshot_from_volume "$GOLDEN" "$BOOT_STAGE" || die "golden snapshot fail"

# SD bootfs <- golden (cmdline + cloud-init haric)
rsync -a "${BOOT_SYNC_EXCLUDES[@]}" "$BOOT_STAGE/" "$BOOT_SD/"
bootfs_rsync_checksum_ok "$BOOT_STAGE" "$BOOT_SD" || die "SD bootfs yazma checksum fail"
log "SD boot firmware/kernel golden'dan yuklendi"

# Hybrid cmdline: her zaman SD root PARTUUID
bak=""
for f in "$BOOT_SD/cmdline.txt.bak-pre-ssd-root" ${BOOT_SSD:+"$BOOT_SSD/cmdline.txt.bak-pre-ssd-root"}; do
  [[ -f "$f" ]] && { bak="$f"; break; }
done

QUIRK="$(detect_usb_quirk)"
if [[ -n "$bak" ]]; then
  base="$(tr -d '\n' < "$bak")"
  base=$(echo "$base" | sed -E \
    's/usb-storage\.quirks=[^ ]* ?//g; s/rootdelay=[0-9]+ ?//g; s/(^| )resize( |$)/ /g; s/  +/ /g')
else
  base="console=serial0,115200 console=tty1 rootfstype=ext4 fsck.repair=yes rootwait plymouth.ignore-serial-consoles"
fi
base=$(echo "$base" | sed -E "s|root=PARTUUID=[^ ]+||g; s/  +/ /g; s/^ //; s/ $//")
base="root=PARTUUID=${SD_ROOT_PARTUUID} rootfstype=ext4 rootwait ${base}"
printf '%s\n' "root=PARTUUID=${SD_ROOT_PARTUUID} rootfstype=ext4 rootwait ${base}" \
  | sed -E 's/  +/ /g; s/^ //; s/ $//' > "$BOOT_SD/cmdline.txt"
apply_jmicron_cmdline_file "$BOOT_SD/cmdline.txt" "$QUIRK"

[[ -f "$BOOT_SD/cmdline.txt.bak-pre-ssd-root" ]] || \
  cp "$BOOT_SD/cmdline.txt.bak-ssd-root-attempt" "$BOOT_SD/cmdline.txt.bak-pre-ssd-root" 2>/dev/null || true
cp "$BOOT_SD/cmdline.txt" "$BOOT_SD/cmdline.txt.bak-hybrid-restore" 2>/dev/null || true

# cloud-init: SD'de kalsin; eksikleri SSD'den tamamla
for f in ssh userconf network-config meta-data; do
  copy_bootfs_file_if_missing "$f" "$BOOT_SD" "${BOOT_SSD:-}"
done
[[ -f "$BOOT_SD/ssh" ]] || touch "$BOOT_SD/ssh"
rm -f "$BOOT_SD/firstrun.sh" "$BOOT_SD/._firstrun.sh" 2>/dev/null || true

hybrid_write_ssd_user_data "$BOOT_SD" "$PROJECT_DIR" || die "user-data (SSD setup) yazilamadi"
grep -q 'pi-ssd-data.service' "$BOOT_SD/user-data" || die "user-data SSD unit eksik"
grep -q 'PI_SSD_CONFIRM_FORMAT=yes' "$BOOT_SD/user-data" || die "user-data format onayi eksik"

for kv in boot_delay=5 usb_max_current_enable=1 hdmi_force_hotplug=1; do
  key="${kv%%=*}"
  cfg="$BOOT_SD/config.txt"
  if grep -q "^${key}=" "$cfg" 2>/dev/null; then
    sed -i '' "s|^${key}=.*|${kv}|" "$cfg"
  else
    echo "$kv" >>"$cfg"
  fi
done

verify_pi4_boot_archives "$BOOT_SD" || die "SD boot archive hala bozuk"
grep -q "root=PARTUUID=${SD_ROOT_PARTUUID}" "$BOOT_SD/cmdline.txt" || die "SD cmdline SD root degil"
wrong_root="$(grep -oE 'root=PARTUUID=[^ ]+' "$BOOT_SD/cmdline.txt" | head -1)"
[[ "$wrong_root" == "root=PARTUUID=${SD_ROOT_PARTUUID}" ]] || die "cmdline root PARTUUID uyumsuz: $wrong_root"
log "SD hybrid cmdline OK: $wrong_root"

sync
diskutil unmount "$BOOT_SD" >/dev/null 2>&1 || true
[[ -n "$BOOT_SSD" ]] && diskutil unmount "$BOOT_SSD" >/dev/null 2>&1 || true

# SSD -> bos veri diski
if [[ "$CONFIRM_WIPE_SSD" == "yes" ]]; then
  log "SSD sifirlaniyor (veri diski — Pi ext4 olusturacak)..."
  diskutil unmountDisk force "$PI_SSD_DISK" >/dev/null 2>&1 || true
  if diskutil eraseDisk free none "$PI_SSD_DISK" >/dev/null 2>&1; then
    log "SSD diskutil eraseDisk ile sifirlandi"
  else
    SSD_R="/dev/r${PI_SSD_DISK#/dev/}"
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
      sudo dd if=/dev/zero of="$SSD_R" bs=1m count=64 status=none || die "SSD sifirlanamadi"
    else
      dd if=/dev/zero of="$SSD_R" bs=1m count=64 status=none || die "SSD sifirlanamadi"
    fi
    log "SSD dd ile sifirlandi"
  fi
  log "SSD bos — ilk boot'ta pi-ssd-data calisacak"
else
  log "WARN: SSD wipe atlandi — CONFIRM_WIPE_SSD=yes ile tekrar calistir"
fi

log "=== Hybrid restore tamam ==="
log "1. SD + SSD Pi'ye tak, Ethernet"
log "2. Ac, ssh @<PI_STATIC_IP>"
log "3. ./scripts/mac/deploy.sh"
log "4. dogrula: findmnt /mnt/ssd && readlink ~/pi-gateway/data"
