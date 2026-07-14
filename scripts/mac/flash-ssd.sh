#!/usr/bin/env bash
# Mac'te Raspberry Pi SSD: test, sil, Trixie/cloud-init ile temiz yaz, dogrula
set -euo pipefail

IMAGER="/Applications/Raspberry Pi Imager.app/Contents/MacOS/rpi-imager"
LOG="${TMPDIR:-/tmp}/pi-ssd-flash.log"

# Resmi Trixie arm64 Desktop (64-bit) — cloud-init destekli
OS_IMAGE_URL="${OS_IMAGE_URL:-https://downloads.raspberrypi.com/raspios_arm64/images/raspios_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64.img.xz}"

PI_HOSTNAME="${PI_HOSTNAME:-batu}"
PI_USER="${PI_USER:-batu}"
PI_PASSWORD="${PI_PASSWORD:-}"
PI_TIMEZONE="${PI_TIMEZONE:-Europe/Istanbul}"
PI_LOCALE="${PI_LOCALE:-tr_TR.UTF-8}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG" >&2; }
die() { log "HATA: $*"; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "Bu script sadece macOS icin"
[[ -x "$IMAGER" ]] || die "Raspberry Pi Imager bulunamadi: $IMAGER"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Disk islemleri icin admin sifresi gerekli..."
  exec sudo -E env \
    PI_HOSTNAME="$PI_HOSTNAME" PI_USER="$PI_USER" PI_PASSWORD="$PI_PASSWORD" \
    PI_TIMEZONE="$PI_TIMEZONE" PI_LOCALE="$PI_LOCALE" OS_IMAGE_URL="$OS_IMAGE_URL" \
    CONFIRM="${CONFIRM:-}" \
    "$0" "$@"
fi

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

write_cloud_init() {
  local boot="$1"
  cat > "$boot/user-data" <<EOF
#cloud-config
hostname: ${PI_HOSTNAME}
manage_etc_hosts: true
timezone: ${PI_TIMEZONE}
locale: ${PI_LOCALE}

users:
  - name: ${PI_USER}
    gecos: Pi Gateway
    groups: users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_password: "${PI_PASSWORD}"
    sudo: ALL=(ALL) NOPASSWD:ALL

enable_ssh: true
ssh_pwauth: true

package_update: true
package_upgrade: false
EOF

  cat > "$boot/network-config" <<EOF
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      optional: false
EOF

  # Legacy yedek (bazi surumlerde hala is gorur)
  touch "$boot/ssh"
  HASH=$(echo -n "$PI_PASSWORD" | openssl passwd -6 -stdin)
  echo "${PI_USER}:${HASH}" > "$boot/userconf"

  # Eski firstrun kalintisini temizle
  rm -f "$boot/firstrun.sh" "$boot/._firstrun.sh" 2>/dev/null || true
}

# Forum kanitli Pi 4 + JMicron JMS583 (152d:0583) duzeltmeleri:
# - usb-storage.quirks=VID:PID:u  → UAS kapat (Geekworm / RPi forum)
# - rootdelay=25                  → SSD gec hazir olursa bekle (JMicron son deneme)
# - boot_delay=5                  → EEPROM USB taramasi icin sure
# - quiet/splash kaldir           → HDMI dusse bile boot log gorunsun
# - hdmi_force_hotplug=1          → sinyal kaybinda HDMI'yi zorla acik tut
apply_pi_usb_boot_fixes() {
  local boot="$1"
  local quirk="${2:-152d:0583:u}"
  local cmdline="$boot/cmdline.txt"
  local config="$boot/config.txt"
  local line

  line=$(tr -d '\n' < "$cmdline")
  line=$(echo "$line" | sed -E 's/usb-storage\.quirks=[^ ]* //g')
  line=$(echo "$line" | sed -E 's/rootdelay=[0-9]+ //g')
  line=$(echo "$line" | sed -E 's/\bquiet\b//g; s/\bsplash\b//g')
  line=$(echo "$line" | sed -E 's/  +/ /g' | sed -E 's/^ +| +$//g')
  echo "usb-storage.quirks=${quirk} rootdelay=25 ${line}" > "$cmdline"

  # config.txt — [all] altina ekle / guncelle
  for kv in "boot_delay=5" "usb_max_current_enable=1" "hdmi_force_hotplug=1"; do
    key="${kv%%=*}"
    if grep -q "^${key}=" "$config" 2>/dev/null; then
      sed -i '' "s|^${key}=.*|${kv}|" "$config"
    else
      echo "$kv" >> "$config"
    fi
  done

  log "Pi USB boot fix: quirks=${quirk}, rootdelay=25, boot_delay=5, hdmi_force_hotplug=1 (quiet/splash kapali, hdmi_drive yok)"
}

detect_usb_quirk() {
  local vid pid
  # YongzhenWeiye / YzWy / jack88888 — Mac ioreg
  vid=$(ioreg -l 2>/dev/null | grep -A40 'YzWy  Disk Device' | grep '"idVendor"' | head -1 | sed 's/.*= //' | tr -d ' ')
  pid=$(ioreg -l 2>/dev/null | grep -A40 'YzWy  Disk Device' | grep '"idProduct"' | head -1 | sed 's/.*= //' | tr -d ' ')
  if [[ -n "$vid" && -n "$pid" && "$vid" =~ ^[0-9]+$ && "$pid" =~ ^[0-9]+$ ]]; then
    printf "%04x:%04x:u" "$vid" "$pid"
    return 0
  fi
  # JMicron JMS583 — forum varsayilani
  echo "152d:0583:u"
}

DISK=$(find_pi_ssd) || die "Pi SSD bulunamadi. USB ile takili oldugundan emin ol."
[[ "$DISK" =~ ^/dev/disk[0-9]+$ ]] || die "Gecersiz disk yolu: '$DISK'"
RDISK="/dev/r${DISK#/dev/}"

INFO=$(diskutil info "$DISK")
SIZE=$(echo "$INFO" | awk -F': *' '/Disk Size/ {print $2}' | head -1)
NAME=$(echo "$INFO" | awk -F': *' '/Device \/ Media Name/ {print $2}' | head -1)

log "=== Pi SSD Flash (Trixie + cloud-init) ==="
log "SSD: $DISK ($NAME, $SIZE)"
log "OS: $OS_IMAGE_URL"
log "Kullanici: $PI_USER / hostname: $PI_HOSTNAME"
log "Log: $LOG"

echo ""
echo "  !!! DIKKAT: $DISK UZERINDEKI TUM VERI SILINECEK !!!"
echo "  1TB 'Batu' diski DEGIL — 256GB Pi SSD olmali."
diskutil list "$DISK"
echo ""
if [[ "${CONFIRM:-}" == "EVET" ]]; then
  log "CONFIRM=EVET (otomatik onay)"
else
  read -r -p "Devam etmek icin 'EVET' yaz: " CONFIRM
  [[ "$CONFIRM" == "EVET" ]] || die "Iptal edildi"
fi

if [[ -z "$PI_PASSWORD" && -f /Volumes/bootfs/user-data ]]; then
  PI_PASSWORD=$(awk -F'"' '/plain_text_password:/ {print $2; exit}' /Volumes/bootfs/user-data || true)
fi
if [[ -z "$PI_PASSWORD" ]]; then
  read -r -s -p "Pi kullanici sifresi ($PI_USER, min 8 karakter): " PI_PASSWORD
  echo
fi
[[ ${#PI_PASSWORD} -ge 8 ]] || die "Sifre en az 8 karakter olmali"

# --- 1. Okuma testi (2GB) ---
log "1/6 Okuma testi (2GB)..."
DD_ERR=$(mktemp)
if ! dd if="$RDISK" of=/dev/null bs=1m count=2048 2>"$DD_ERR"; then
  DD_MSG=$(cat "$DD_ERR")
  log "dd: $DD_MSG"
  rm -f "$DD_ERR"
  die "SSD okuma hatasi — adaptör/kablo bozuk olabilir."
fi
rm -f "$DD_ERR"
log "Okuma testi OK"

# --- 2. Unmount + sifirla ---
log "2/6 Disk unmount ve partition tablosu siliniyor..."
diskutil unmountDisk force "$DISK" >>"$LOG" 2>&1 || true
dd if=/dev/zero of="$RDISK" bs=1m count=100 2>>"$LOG" || die "Disk sifirlanamadi"

# --- 3. Imager ile yaz ---
log "3/6 Imager ile yaziliyor (10-25 dk, internet gerekebilir)..."
"$IMAGER" --cli \
  --disable-verify \
  --enable-writing-system-drives \
  --quiet \
  "$OS_IMAGE_URL" \
  "$RDISK" >>"$LOG" 2>&1 || die "Imager yazimi basarisiz. Log: $LOG"
log "Yazim tamamlandi"

# --- 4. cloud-init ayarlari ---
log "4/6 cloud-init + SSH ayarlari..."
sleep 3
diskutil mount "${DISK}s1" >>"$LOG" 2>&1 || true

BOOT=""
for _ in 1 2 3 4 5; do
  [[ -d /Volumes/bootfs ]] && { BOOT="/Volumes/bootfs"; break; }
  sleep 2
done
[[ -n "$BOOT" ]] || die "bootfs mount edilemedi"

write_cloud_init "$BOOT"
QUIRK=$(detect_usb_quirk)
apply_pi_usb_boot_fixes "$BOOT" "$QUIRK"
log "user-data, network-config, ssh, USB quirks ayarlandi"

sync
diskutil unmount "$BOOT" >>"$LOG" 2>&1 || true

# --- 5. Yazma sonrasi okuma testi ---
log "5/6 Yazma sonrasi okuma testi (512MB)..."
DD_ERR=$(mktemp)
if ! dd if="$RDISK" of=/dev/null bs=1m count=512 2>"$DD_ERR"; then
  log "dd: $(cat "$DD_ERR")"
  rm -f "$DD_ERR"
  die "Yazma sonrasi okuma hatasi — adaptör sorunlu."
fi
rm -f "$DD_ERR"
log "Yazma sonrasi okuma OK"

# --- 6. Dogrulama ---
log "6/6 Dogrulama..."
diskutil mount "${DISK}s1" >>"$LOG" 2>&1 || true
sleep 2
[[ -f /Volumes/bootfs/cmdline.txt ]] || die "cmdline.txt eksik"
grep -q "root=PARTUUID" /Volumes/bootfs/cmdline.txt || die "cmdline root= eksik"
grep -q "resize" /Volumes/bootfs/cmdline.txt && log "cmdline resize: OK (ilk acilista disk genisler)"
[[ -f /Volumes/bootfs/kernel8.img ]] || die "kernel8.img eksik"
[[ -f /Volumes/bootfs/user-data ]] || die "user-data eksik"
grep -q "^hostname: ${PI_HOSTNAME}" /Volumes/bootfs/user-data || die "hostname cloud-init'te yok"
grep -q "^enable_ssh: true" /Volumes/bootfs/user-data || die "enable_ssh cloud-init'te yok"
grep -q "usb-storage.quirks=" /Volumes/bootfs/cmdline.txt || die "USB quirks cmdline'da yok"
grep -q "boot_delay=" /Volumes/bootfs/config.txt || die "boot_delay config'te yok"
log "cmdline: $(cat /Volumes/bootfs/cmdline.txt)"

diskutil list "$DISK" >>"$LOG" 2>&1
diskutil unmount /Volumes/bootfs >>"$LOG" 2>&1 || true

log ""
log "=== TAMAMLANDI ==="
log "1. Mac'te SSD'yi guvenle cikar"
log "2. Pi KAPALI: SD cikar"
log "3. SSD → SIYAH USB 2.0 port (JMicron icin once 2.0 dene)"
log "4. HDMI 0 + Ethernet + resmi 5V/3A guc (baska USB cihaz YOK)"
log "5. Ac — ilk acilis 5-10 dk (resize + cloud-init). quiet kapali, log gorunmeli."
log "6. ssh ${PI_USER}@<PI_IP>"
log ""
if echo "$NAME" | grep -qi yongzhen; then
  log "UYARI: YongzhenWeiye = JMicron JMS583. HDMI hala duserse adaptör/güç sorunu."
  log "       Kalici: ASMedia chipsetli kutu (UGREEN/Sabrent) veya guclu USB hub."
fi
