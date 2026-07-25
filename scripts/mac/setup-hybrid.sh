#!/usr/bin/env bash
# Mac: SD (OS boot) + SSD (veri diski) hibrit kurulum
set -euo pipefail

IMAGER="/Applications/Raspberry Pi Imager.app/Contents/MacOS/rpi-imager"
OS_IMAGE_URL="${OS_IMAGE_URL:-https://downloads.raspberrypi.com/raspios_arm64/images/raspios_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64.img.xz}"
LOG="${TMPDIR:-/tmp}/pi-hybrid-setup.log"

PI_HOSTNAME="${PI_HOSTNAME:-pi-gateway}"
PI_USER="${PI_USER:-pi}"
PI_PASSWORD="${PI_PASSWORD:-}"
PI_TIMEZONE="${PI_TIMEZONE:-Europe/Istanbul}"
PI_LOCALE="${PI_LOCALE:-tr_TR.UTF-8}"
SSD_LABEL="${SSD_LABEL:-pi-data}"
SSD_MOUNT="${SSD_MOUNT:-/mnt/ssd}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG" >&2; }
die() { log "HATA: $*"; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "Sadece macOS"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo -E env \
    PI_HOSTNAME="$PI_HOSTNAME" PI_USER="$PI_USER" PI_PASSWORD="$PI_PASSWORD" \
    PI_TIMEZONE="$PI_TIMEZONE" PI_LOCALE="$PI_LOCALE" OS_IMAGE_URL="$OS_IMAGE_URL" \
    SSD_LABEL="$SSD_LABEL" SSD_MOUNT="$SSD_MOUNT" CONFIRM="${CONFIRM:-}" \
    "$0" "$@"
fi

[[ -x "$IMAGER" ]] || die "Raspberry Pi Imager yok: $IMAGER"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PI_SETUP_SCRIPT="${PI_SETUP_SCRIPT:-$PROJECT_DIR/scripts/pi/setup-ssd-data.sh}"
[[ -f "$PI_SETUP_SCRIPT" ]] || die "Eksik: $PI_SETUP_SCRIPT"
# shellcheck source=../lib/hybrid-cloud-init.sh
source "$SCRIPT_DIR/../lib/hybrid-cloud-init.sh"

disk_size_gb() {
  diskutil info "$1" 2>/dev/null | awk -F': *' '/Disk Size/ {print $2}' | grep -oE '[0-9]+' | head -1
}

find_sd_disk() {
  local disk gb
  while read -r disk; do
    [[ -z "$disk" ]] && continue
    diskutil info "$disk" 2>/dev/null | grep -q "Internal" && continue
    gb="$(disk_size_gb "$disk")"
    [[ -n "$gb" ]] || continue
    # 32GB SD (~31-32), 1TB haric
    if [[ "$gb" -ge 28 && "$gb" -le 40 ]]; then
      echo "$disk"
      return 0
    fi
  done < <(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+ \(external/ {print $1}' | tr -d ':')
  return 1
}

find_ssd_disk() {
  local disk gb
  while read -r disk; do
    [[ -z "$disk" ]] && continue
    diskutil info "$disk" 2>/dev/null | grep -q "Internal" && continue
    gb="$(disk_size_gb "$disk")"
    [[ -n "$gb" ]] || continue
    if [[ "$gb" -ge 200 && "$gb" -le 300 ]]; then
      echo "$disk"
      return 0
    fi
  done < <(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+ \(external/ {print $1}' | tr -d ':')
  return 1
}

write_cloud_init_files() {
  local dir="$1"
  hybrid_write_fresh_install_cloud_init \
    "$dir" "$PI_SETUP_SCRIPT" "$PI_USER" "$PI_HOSTNAME" "$PI_PASSWORD" \
    "$PI_TIMEZONE" "$PI_LOCALE" "$SSD_MOUNT"
}

apply_sd_post_flash() {
  local boot="$1"
  apply_sd_usb_storage_quirks "$boot"
  touch "$boot/ssh"
  cp -f "$CLOUD_INIT_DIR/userconf" "$boot/userconf" 2>/dev/null || true
  cp -f "$CLOUD_INIT_DIR/meta-data" "$boot/meta-data" 2>/dev/null || true
  rm -f "$boot/firstrun.sh" "$boot/._firstrun.sh" 2>/dev/null || true
}

apply_sd_usb_storage_quirks() {
  local boot="$1"
  local cmdline="$boot/cmdline.txt"
  local line
  line=$(tr -d '\n' < "$cmdline")
  line=$(echo "$line" | sed -E 's/usb-storage\.quirks=[^ ]* //g')
  line=$(echo "$line" | sed -E 's/\bquiet\b//g; s/\bsplash\b//g')
  line=$(echo "$line" | sed -E 's/  +/ /g' | sed -E 's/^ +| +$//g')
  # SD boot; quirks sadece takili JMicron SSD veri diski icin
  echo "usb-storage.quirks=152d:0583:u ${line}" > "$cmdline"

  local config="$boot/config.txt"
  for kv in "hdmi_force_hotplug=1" "usb_max_current_enable=1"; do
    key="${kv%%=*}"
    if grep -q "^${key}=" "$config" 2>/dev/null; then
      sed -i '' "s|^${key}=.*|${kv}|" "$config"
    else
      printf '\n%s\n' "$kv" >> "$config"
    fi
  done
}

SD_DISK=$(find_sd_disk) || die "SD kart bulunamadi (~32GB harici disk)"
SSD_DISK=$(find_ssd_disk) || die "SSD bulunamadi (~256GB harici disk)"
SD_R="/dev/r${SD_DISK#/dev/}"
SSD_R="/dev/r${SSD_DISK#/dev/}"

SD_NAME=$(diskutil info "$SD_DISK" | awk -F': *' '/Device \/ Media Name/ {print $2}' | head -1)
SSD_NAME=$(diskutil info "$SSD_DISK" | awk -F': *' '/Device \/ Media Name/ {print $2}' | head -1)

log "=== Hibrit Kurulum (SD boot + SSD veri) ==="
log "SD:  $SD_DISK ($SD_NAME)"
log "SSD: $SSD_DISK ($SSD_NAME)"
log "OS:  $OS_IMAGE_URL"
log "Log: $LOG"
echo ""
diskutil list "$SD_DISK"
echo ""
diskutil list "$SSD_DISK"
echo ""
echo "  !!! $SD_DISK (SD) ve $SSD_DISK (SSD) SIFIRLANACAK !!!"
echo "  1TB Batu diski DOKUNULMAZ."
if [[ "${CONFIRM:-}" == "EVET" ]]; then
  log "CONFIRM=EVET"
else
  read -r -p "Devam: EVET yaz: " c
  [[ "$c" == "EVET" ]] || die "Iptal"
fi

if [[ -z "$PI_PASSWORD" ]]; then
  for vol in /Volumes/bootfs "/Volumes/bootfs 1"; do
    [[ -f "$vol/user-data" ]] || continue
    PI_PASSWORD=$(awk -F'"' '/plain_text_password:/ {print $2; exit}' "$vol/user-data" || true)
    [[ -n "$PI_PASSWORD" ]] && break
  done
fi
if [[ -z "$PI_PASSWORD" ]]; then
  read -r -s -p "Pi sifresi ($PI_USER, min 8): " PI_PASSWORD
  echo
fi
[[ ${#PI_PASSWORD} -ge 8 ]] || die "Sifre min 8 karakter"

CLOUD_INIT_DIR="${TMPDIR:-/tmp}/pi-hybrid-cloud-init"
write_cloud_init_files "$CLOUD_INIT_DIR"
log "cloud-init dosyalari: $CLOUD_INIT_DIR"
grep -q "encoding: b64" "$CLOUD_INIT_DIR/user-data" || die "cloud-init uretimi basarisiz"

# --- 1. SSD sifirla (veri diski; Pi ilk acilista ext4 yapacak) ---
log "1/5 SSD sifirlaniyor (partition tablosu siliniyor)..."
diskutil unmountDisk force "$SSD_DISK" >>"$LOG" 2>&1 || true
dd if=/dev/zero of="$SSD_R" bs=1m count=64 >>"$LOG" 2>&1 || die "SSD sifirlanamadi"
log "SSD hazir (bos disk — Pi ilk acilista ${SSD_LABEL} ext4 olusturur)"

# --- 2. SD sifirla + yaz ---
log "2/5 SD sifirlaniyor..."
diskutil unmountDisk force "$SD_DISK" >>"$LOG" 2>&1 || true
dd if=/dev/zero of="$SD_R" bs=1m count=64 >>"$LOG" 2>&1 || die "SD sifirlanamadi"

log "3/5 SD'ye Raspberry Pi OS yaziliyor (10-25 dk)..."
"$IMAGER" --cli \
  --enable-writing-system-drives \
  --disable-eject \
  --cloudinit-userdata "$CLOUD_INIT_DIR/user-data" \
  --cloudinit-networkconfig "$CLOUD_INIT_DIR/network-config" \
  --quiet \
  "$OS_IMAGE_URL" \
  "$SD_R" >>"$LOG" 2>&1 || die "Imager basarisiz. Log: $LOG"

# --- 3. cloud-init + quirks ---
log "4/5 SD bootfs yapilandiriliyor..."
sleep 3
diskutil mount "${SD_DISK}s1" >>"$LOG" 2>&1 || true
BOOT=""
for _ in 1 2 3 4 5 6; do
  for vol in /Volumes/bootfs "/Volumes/bootfs 1"; do
    if [[ -d "$vol" ]] && diskutil info "$vol" 2>/dev/null | grep -q "$SD_DISK"; then
      BOOT="$vol"
      break 2
    fi
  done
  [[ -d /Volumes/bootfs ]] && diskutil info /Volumes/bootfs 2>/dev/null | grep -q "$SD_DISK" && { BOOT="/Volumes/bootfs"; break; }
  sleep 2
done
[[ -n "$BOOT" ]] || die "SD bootfs mount edilemedi"

apply_sd_post_flash "$BOOT"
sync
diskutil unmount "$BOOT" >>"$LOG" 2>&1 || true

# --- 4. Dogrulama ---
log "5/5 Dogrulama..."
diskutil mount "${SD_DISK}s1" >>"$LOG" 2>&1 || true
sleep 2
BOOT="/Volumes/bootfs"
[[ -f "$BOOT/cmdline.txt" ]] || BOOT="/Volumes/bootfs 1"
[[ -f "$BOOT/cmdline.txt" ]] || die "cmdline yok"
grep -q "usb-storage.quirks=152d:0583:u" "$BOOT/cmdline.txt" || die "quirks yok"
grep -q "^hostname: ${PI_HOSTNAME}" "$BOOT/user-data" || die "hostname yok"
grep -q "encoding: b64" "$BOOT/user-data" || die "SSD setup script cloud-init'te yok"
grep -q "pi-ssd-data.service" "$BOOT/user-data" || die "systemd unit cloud-init'te yok"
[[ -f "$BOOT/kernel8.img" ]] || die "kernel eksik"

log "cmdline: $(cat "$BOOT/cmdline.txt")"
diskutil list "$SD_DISK" >>"$LOG"
diskutil list "$SSD_DISK" >>"$LOG"
diskutil unmount "$BOOT" >>"$LOG" 2>&1 || true

cat <<EOF

=== HIBRIT KURULUM TAMAM ===

SD kart ($SD_DISK):
  - Raspberry Pi OS Trixie (boot + root)
  - Kullanici: ${PI_USER} / hostname: ${PI_HOSTNAME}
  - SSH acik
  - JMicron quirks (SSD veri diski icin)

SSD ($SSD_DISK):
  - Bos disk (sifirlandi)
  - Ilk acilista otomatik: ext4 label=${SSD_LABEL}, mount=${SSD_MOUNT}
  - Veri: ${SSD_MOUNT}/pi-gateway-data/

Pi'de:
  1. SSD tak (USB 2.0 veya 3.0 — boot SD'den)
  2. SD tak
  3. Ac, 3-5 dk bekle (cloud-init + SSD format)
  4. ssh ${PI_USER}@<IP>
  5. lsblk && df -h ${SSD_MOUNT}
  6. Mac'ten: make install

EOF
