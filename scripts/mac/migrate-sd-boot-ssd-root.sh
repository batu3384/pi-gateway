#!/usr/bin/env bash
# Mac: SD bootfs + SSD rootfs (A mimarisi) cutover
# SD = yalnizca boot; SSD = temiz Pi OS rootfs
#
# Kullanim:
#   PI_PASSWORD=... CONFIRM=yes ./scripts/mac/migrate-sd-boot-ssd-root.sh
# Opsiyonel: PI_SD_DISK=/dev/diskXX PI_SSD_DISK=/dev/diskYY
set -euo pipefail

IMAGER="/Applications/Raspberry Pi Imager.app/Contents/MacOS/rpi-imager"
LOG="${TMPDIR:-/tmp}/pi-ssd-root-migrate.log"
OS_IMAGE_URL="${OS_IMAGE_URL:-https://downloads.raspberrypi.com/raspios_arm64/images/raspios_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64.img.xz}"

PI_HOSTNAME="${PI_HOSTNAME:-batu}"
PI_USER="${PI_USER:-batu}"
PI_PASSWORD="${PI_PASSWORD:-}"
PI_TIMEZONE="${PI_TIMEZONE:-Europe/Istanbul}"
PI_LOCALE="${PI_LOCALE:-tr_TR.UTF-8}"
CONFIRM="${CONFIRM:-}"
PI_SD_DISK="${PI_SD_DISK:-}"
PI_SSD_DISK="${PI_SSD_DISK:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/password-policy.sh
source "$SCRIPT_DIR/../lib/password-policy.sh"
# shellcheck source=../lib/usb-quirk.sh
source "$SCRIPT_DIR/../lib/usb-quirk.sh"
# shellcheck source=../lib/ssd-root-cmdline.sh
source "$SCRIPT_DIR/../lib/ssd-root-cmdline.sh"
# shellcheck source=../lib/bootfs-sync.sh
source "$SCRIPT_DIR/../lib/bootfs-sync.sh"
# shellcheck source=../lib/mbr-partuuid.sh
source "$SCRIPT_DIR/../lib/mbr-partuuid.sh"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG" >&2; }
die() { log "HATA: $*"; exit 1; }

BOOT_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pi-ssd-boot.XXXXXX")"
trap 'rm -rf "$BOOT_STAGE"' EXIT

[[ "$(uname)" == "Darwin" ]] || die "Sadece macOS"
[[ -x "$IMAGER" ]] || die "Raspberry Pi Imager yok: $IMAGER"
[[ -n "$PI_PASSWORD" ]] || die "PI_PASSWORD gerekli"
[[ "$CONFIRM" == "yes" ]] || die "SSD silinecek. Onay: CONFIRM=yes"
enforce_password_policy "$PI_PASSWORD" "PI_PASSWORD" || die "sifre politikasi"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo -E env \
    PI_HOSTNAME="$PI_HOSTNAME" PI_USER="$PI_USER" PI_PASSWORD="$PI_PASSWORD" \
    PI_TIMEZONE="$PI_TIMEZONE" PI_LOCALE="$PI_LOCALE" OS_IMAGE_URL="$OS_IMAGE_URL" \
    CONFIRM="$CONFIRM" PI_SD_DISK="$PI_SD_DISK" PI_SSD_DISK="$PI_SSD_DISK" \
    "$0" "$@"
fi

disk_size_gb() {
  diskutil info "$1" 2>/dev/null | awk -F': *' '/Disk Size/ {print $2}' | grep -oE '[0-9]+' | head -1
}

validate_external_whole_disk() {
  local label="$1" disk="$2" min_gb="$3" max_gb="$4" info gb
  [[ "$disk" =~ ^/dev/disk[0-9]+$ ]] || die "$label: whole disk yolu bekleniyor: $disk"
  info="$(diskutil info "$disk" 2>/dev/null)" || die "$label: diskutil info basarisiz: $disk"
  echo "$info" | grep -qE '^   Whole: +Yes$' || die "$label: whole disk degil: $disk"
  echo "$info" | grep -qE '^   Device Location: +External$' || die "$label: external disk degil: $disk"
  echo "$info" | grep -qE '^   Media Read-Only: +No$' || die "$label: salt-okunur veya bilinmeyen disk: $disk"
  gb="$(disk_size_gb "$disk")"
  [[ -n "$gb" && "$gb" -ge "$min_gb" && "$gb" -le "$max_gb" ]] || \
    die "$label: boyut ${gb:-?}GB, beklenen ${min_gb}-${max_gb}GB: $disk"
}

# /dev/diskNs1 -> mount point (yoksa bos)
mount_point_of() {
  diskutil info "$1" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2; exit}'
}

# disk device'in bootfs partition'ini mount et, yol dondur
mount_bootfs() {
  local disk="$1" part="${1}s1" mp
  diskutil mount "$part" >/dev/null 2>&1 || true
  sleep 1
  mp="$(mount_point_of "$part")"
  [[ -n "$mp" && "$mp" != "Not applicable" && -f "$mp/cmdline.txt" ]] || return 1
  echo "$mp"
}

cmdline_root() {
  grep -oE 'root=[^ ]+' "$1/cmdline.txt" 2>/dev/null | head -1
}

find_disks_by_size() {
  local min_gb="$1" max_gb="$2"
  local disk gb
  while read -r disk; do
    [[ -z "$disk" ]] && continue
    diskutil info "$disk" 2>/dev/null | grep -q "Internal" && continue
    gb="$(disk_size_gb "$disk")"
    [[ -n "$gb" ]] || continue
    if [[ "$gb" -ge "$min_gb" && "$gb" -le "$max_gb" ]]; then
      echo "$disk"
    fi
  done < <(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+ \(external/ {print $1}' | tr -d ':')
}

pick_one_disk() {
  local label="$1" min_gb="$2" max_gb="$3" forced="$4"
  local -a cands=()
  local d
  if [[ -n "$forced" ]]; then
    validate_external_whole_disk "$label" "$forced" "$min_gb" "$max_gb"
    echo "$forced"
    return 0
  fi
  while IFS= read -r d; do
    [[ -n "$d" ]] && cands+=("$d")
  done < <(find_disks_by_size "$min_gb" "$max_gb")
  if [[ ${#cands[@]} -eq 0 ]]; then
    die "$label bulunamadi (${min_gb}-${max_gb}GB)"
  fi
  if [[ ${#cands[@]} -gt 1 ]]; then
    log "Birden fazla $label adayi: ${cands[*]}"
    die "PI_SD_DISK / PI_SSD_DISK ile netlestir"
  fi
  echo "${cands[0]}"
}

SD_DISK="$(pick_one_disk SD 8 512 "$PI_SD_DISK")"
SSD_DISK="$(pick_one_disk SSD 32 4096 "$PI_SSD_DISK")"
[[ "$SD_DISK" != "$SSD_DISK" ]] || die "SD ve SSD ayni disk"
validate_external_whole_disk SD "$SD_DISK" 8 512
validate_external_whole_disk SSD "$SSD_DISK" 32 4096

log "SD : $SD_DISK ($(disk_size_gb "$SD_DISK")GB)"
log "SSD: $SSD_DISK ($(disk_size_gb "$SSD_DISK")GB) — SILINECEK VE YENIDEN YAZILACAK"

# Cutover oncesi SD root (yanlis kopyalamayi yakalamak icin)
BOOT_SD_PRE=""
BOOT_SD_PRE="$(mount_bootfs "$SD_DISK")" || true
SD_ROOT_BEFORE=""
if [[ -n "$BOOT_SD_PRE" ]]; then
  SD_ROOT_BEFORE="$(cmdline_root "$BOOT_SD_PRE" || true)"
  log "SD mevcut root (flash oncesi): ${SD_ROOT_BEFORE:-yok}"

  # Rollback noktasi SSD silinmeden once kalici olusturulmali. Daha once
  # cutover yapilmis bir SD'yi ikinci kez flash etmeyi de engelle.
  SD_BACKUP="$BOOT_SD_PRE/cmdline.txt.bak-pre-ssd-root"
  if [[ -f "$SD_BACKUP" ]]; then
    OLD_BACKUP_ROOT="$(grep -oE 'root=[^ ]+' "$SD_BACKUP" | head -1 || true)"
    [[ "$OLD_BACKUP_ROOT" == root=PARTUUID=* ]] || die "mevcut SD rollback backup gecersiz: ${OLD_BACKUP_ROOT:-yok}"
    [[ "$SD_ROOT_BEFORE" == "$OLD_BACKUP_ROOT" ]] || {
      die "SD zaten cutover edilmis veya backup eski root ile uyusmuyor — SSD flash edilmedi"
    }
    log "Mevcut SD rollback backup korunuyor: $OLD_BACKUP_ROOT"
  else
    [[ -n "$SD_ROOT_BEFORE" ]] || die "SD mevcut root okunamadi — rollback backup olusturulamadi"
    cp "$BOOT_SD_PRE/cmdline.txt" "$SD_BACKUP"
    log "SD rollback backup flash oncesi olusturuldu: $SD_BACKUP"
  fi
  sync
  diskutil unmount "$(mount_point_of "${SD_DISK}s1")" >/dev/null 2>&1 || true
fi

sleep 2
SSD_RDISK="${SSD_DISK/disk/rdisk}"

log "SSD unmount + flash (Imager, 10-25 dk)..."
diskutil unmountDisk force "$SSD_DISK" >>"$LOG" 2>&1 || true
"$IMAGER" --cli \
  --enable-writing-system-drives \
  --quiet \
  --disable-eject \
  "$OS_IMAGE_URL" \
  "$SSD_RDISK" 2>&1 | tee -a "$LOG" || die "Imager SSD yazimi basarisiz. Log: $LOG"
log "SSD yazim tamamlandi"

sleep 3
BOOT_SSD="$(mount_bootfs "$SSD_DISK")" || die "SSD bootfs mount edilemedi (${SSD_DISK}s1)"
log "SSD bootfs: $BOOT_SSD (disk=$(basename "$SSD_DISK"))"

# Guvenlik: mount noktasi gercekten SSD partition
# diskutil info Mount Point ile device esle (space iceren volume adlari icin)
ssd_part_mp="$(mount_point_of "${SSD_DISK}s1")"
[[ "$ssd_part_mp" == "$BOOT_SSD" ]] || \
  die "SSD bootfs path uyusmuyor: mount_bootfs=$BOOT_SSD diskutil=$ssd_part_mp"

HASH="$(printf '%s' "$PI_PASSWORD" | openssl passwd -6 -stdin)"

cat > "$BOOT_SSD/user-data" <<EOF
#cloud-config
hostname: ${PI_HOSTNAME}
manage_etc_hosts: true
timezone: ${PI_TIMEZONE}
locale: ${PI_LOCALE}
users:
  - name: ${PI_USER}
    gecos: Pi Gateway
    groups: users,adm,dialout,netdev,sudo,gpio,i2c,spi
    shell: /bin/bash
    lock_passwd: false
    passwd: '${HASH}'
    sudo: ALL=(ALL) NOPASSWD:ALL
enable_ssh: true
ssh_pwauth: true
package_update: false
EOF

cat > "$BOOT_SSD/network-config" <<'EOF'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      optional: false
EOF

touch "$BOOT_SSD/ssh"
echo "${PI_USER}:${HASH}" > "$BOOT_SSD/userconf"
rm -f "$BOOT_SSD/firstrun.sh" 2>/dev/null || true

QUIRK="$(detect_usb_quirk)"

CMDLINE_SSD="$BOOT_SSD/cmdline.txt"
line=$(tr -d '\n' < "$CMDLINE_SSD")
printf '%s\n' "$(build_ssd_root_cmdline "$QUIRK" "$line")" > "$CMDLINE_SSD"

SSD_ROOT_SPEC="$(cmdline_root "$BOOT_SSD")"
[[ -n "$SSD_ROOT_SPEC" ]] || die "SSD cmdline'da root= yok"
[[ "$SSD_ROOT_SPEC" == root=PARTUUID=* ]] || die "SSD root PARTUUID degil: $SSD_ROOT_SPEC"

# CRITICAL: eski SD root'u yanlislikla kopyalama
if [[ -n "$SD_ROOT_BEFORE" && "$SSD_ROOT_SPEC" == "$SD_ROOT_BEFORE" ]]; then
  die "SSD root ($SSD_ROOT_SPEC) flash oncesi SD root ile AYNI — yanlis bootfs veya PARTUUID carpismasi. Durduruldu."
fi

log "SSD root (dogru kaynak): $SSD_ROOT_SPEC"
sync

# SSD bootfs'i once Mac'te snapshot'la.
rsync -a "${BOOT_SYNC_EXCLUDES[@]}" "$BOOT_SSD/" "$BOOT_STAGE/"
bootfs_rsync_checksum_ok "$BOOT_SSD" "$BOOT_STAGE" || \
  die "SSD bootfs snapshot checksum dogrulamasi basarisiz — kaynak/USB kararsiz"
verify_pi4_boot_archives "$BOOT_STAGE" || die "SSD boot archive bozuk — Imager yazimi veya USB okuyucu suphesi"
log "SSD bootfs snapshot checksum OK: $BOOT_STAGE"

diskutil unmount "$BOOT_SSD" >/dev/null 2>&1 || true
diskutil unmountDisk force "$SSD_DISK" >/dev/null 2>&1 || true

# --- SD bootfs guncelle ---
log "SD bootfs guncelleniyor..."
BOOT_SD="$(mount_bootfs "$SD_DISK")" || die "SD bootfs mount edilemedi (${SD_DISK}s1)"
sd_part_mp="$(mount_point_of "${SD_DISK}s1")"
[[ "$sd_part_mp" == "$BOOT_SD" ]] || \
  die "SD bootfs path uyusmuyor: mount_bootfs=$BOOT_SD diskutil=$sd_part_mp"
[[ "$BOOT_SD" != "$BOOT_SSD" ]] || die "SSD ve SD bootfs ayni mount path'e geldi — kaynak/hedef karisikligi engellendi"

# SD, SSD root'a giden firmware/kernel/initramfs kaynagi olmali. Eski SD
# initramfs'i korumak JMicron USB root surucusunu kaybettirebilir. Cutover
# backup'i ve SD'ye ozel cmdline dosyalari korunur; cloud-init snapshot'tan
# kopyalanir.
rsync -a "${BOOT_SYNC_EXCLUDES[@]}" "$BOOT_STAGE/" "$BOOT_SD/"
bootfs_rsync_checksum_ok "$BOOT_STAGE" "$BOOT_SD" || \
  die "SD bootfs yazma checksum dogrulamasi basarisiz — SD/USB okuyucu kararsiz"
log "SSD boot firmware/kernel/initramfs SD bootfs'e checksum ile esitlendi"

printf '%s\n' "$(build_ssd_root_cmdline "$QUIRK" "$(tr -d '\n' < "$CMDLINE_SSD")")" > "$BOOT_SD/cmdline.txt"

# Pi firmware SD bootfs'ten acilir — cloud-init de SD'de olmali
log "cloud-init SD bootfs'e kopyalaniyor..."
sync_boot_partition_cloud_init "$BOOT_STAGE" "$BOOT_SD"

CONFIG="$BOOT_SD/config.txt"
for kv in "boot_delay=5" "usb_max_current_enable=1" "hdmi_force_hotplug=1"; do
  key="${kv%%=*}"
  if grep -q "^${key}=" "$CONFIG" 2>/dev/null; then
    sed -i '' "s|^${key}=.*|${kv}|" "$CONFIG"
  else
    echo "$kv" >> "$CONFIG"
  fi
done

# SD artik SSD root'a bakmali
SD_ROOT_AFTER="$(cmdline_root "$BOOT_SD")"
[[ "$SD_ROOT_AFTER" == "$SSD_ROOT_SPEC" ]] || die "SD cmdline yazimi basarisiz: $SD_ROOT_AFTER != $SSD_ROOT_SPEC"
if [[ -n "$SD_ROOT_BEFORE" && "$SD_ROOT_AFTER" == "$SD_ROOT_BEFORE" ]]; then
  die "SD cmdline hala eski root — yazma basarisiz"
fi

log "SD cmdline OK: $SD_ROOT_AFTER"
sync

# Her iki bootfs mount iken verify
diskutil mount "${SSD_DISK}s1" >/dev/null 2>&1 || true
sleep 1
if [[ -x "$SCRIPT_DIR/verify-ssd-root.sh" ]]; then
  PI_SD_DISK="$SD_DISK" PI_SSD_DISK="$SSD_DISK" bash "$SCRIPT_DIR/verify-ssd-root.sh" || \
    die "verify-ssd-root basarisiz — cutover GUVENLI DEGIL"
fi

diskutil unmountDisk force "$SD_DISK" >/dev/null 2>&1 || true
diskutil unmountDisk force "$SSD_DISK" >/dev/null 2>&1 || true

log "=== Cutover hazir ==="
log "1. SSD + SD Pi'ye tak (SSD = mavi USB 3.0)"
log "2. Ac, 3-5 dk bekle (resize + cloud-init)"
log "3. ssh ${PI_USER}@IP — sifre: (PI_PASSWORD)"
log "4. findmnt -n -o SOURCE /   # mmcblk OLMAMALI"
log "5. Mac .env: STORAGE_TYPE=ssd-root && ./scripts/mac/deploy.sh"
log "6. Ilk giriste sifreyi degistir (passwd)"
log "EEPROM (Pi ilk acilista): CONFIRM_EEPROM_FIX=yes sudo bash scripts/pi/fix-eeprom-usb-ssd.sh"
log "Mac onarim: PI_SD_DISK=... PI_SSD_DISK=... ./scripts/mac/repair-cutover-bootfs.sh"
log "Log: $LOG"
