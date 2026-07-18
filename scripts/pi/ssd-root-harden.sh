#!/usr/bin/env bash
# Pi: ssd-root ilk boot sonrasi sertlestirme
# - root SSD mi?
# - EEPROM BOOT_ORDER / USB_MSD
# - zayif sifre uyarisi + ssh key onerisi
# - legacy SD neutralize (opsiyonel)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
CONFIRM_NEUTRALIZE="${CONFIRM_NEUTRALIZE:-false}"
CONFIRM_EEPROM_FIX="${CONFIRM_EEPROM_FIX:-no}"
LOG_TAG="pi-gateway-ssd-root-harden"

log() { echo "[ssd-root-harden] $*"; logger -t "$LOG_TAG" "$*" 2>/dev/null || true; }
die() { log "HATA: $*"; exit 1; }
ok() { log "OK: $*"; }

# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && set -a && source "$REMOTE_DIR/.env" && set +a
STORAGE_TYPE="${STORAGE_TYPE:-hybrid}"

root_src="$(findmnt -n -o SOURCE / || true)"
[[ -n "$root_src" ]] || die "root mount okunamadi"

if echo "$root_src" | grep -q mmcblk; then
  die "root hala SD ($root_src). Cutover basarisiz — SD+SSD Mac'te verify-ssd-root calistir"
fi
ok "root SSD uzerinde: $root_src"

if [[ "$STORAGE_TYPE" != "ssd-root" && "$STORAGE_TYPE" != "ssd" ]]; then
  log "WARN: STORAGE_TYPE=$STORAGE_TYPE — .env'de ssd-root yap"
fi

# Root RW
if findmnt -n -o OPTIONS / | tr ',' '\n' | grep -qx ro; then
  die "root read-only"
fi
ok "root read-write"

# EEPROM
if command -v rpi-eeprom-config >/dev/null 2>&1; then
  eeprom="$(sudo rpi-eeprom-config 2>/dev/null || true)"
  if echo "$eeprom" | grep -qE '^BOOT_ORDER=0xf41$'; then
    ok "EEPROM BOOT_ORDER SD-oncelikli gorunuyor"
  elif echo "$eeprom" | grep -q 'BOOT_ORDER='; then
    order="$(echo "$eeprom" | grep BOOT_ORDER= | head -1)"
    log "WARN: $order — A mimarisi icin BOOT_ORDER=0xf41 onerilir (SD once)"
  else
    log "WARN: BOOT_ORDER okunamadi"
  fi
  eeprom_missing=0
  declare -A expected_eeprom=(
    [USB_MSD_PWR_OFF_TIME]=0
    [USB_MSD_DISCOVER_TIMEOUT]=25000
    [USB_MSD_STARTUP_DELAY]=5000
  )
  for key in "${!expected_eeprom[@]}"; do
    expected="${expected_eeprom[$key]}"
    actual="$(echo "$eeprom" | awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}')"
    if [[ "$actual" == "$expected" ]]; then
      ok "EEPROM $key set"
    else
      log "WARN: EEPROM $key=${actual:-missing}, beklenen $expected — docs/SSD-JMICRON-FIX.md"
      eeprom_missing=1
    fi
  done
  if [[ "${eeprom_missing:-0}" -eq 1 ]] && [[ -x "$REMOTE_DIR/scripts/pi/fix-eeprom-usb-ssd.sh" ]]; then
    if [[ "$CONFIRM_EEPROM_FIX" == "yes" ]]; then
      CONFIRM_EEPROM_FIX=yes ARCH=A bash "$REMOTE_DIR/scripts/pi/fix-eeprom-usb-ssd.sh" || \
        log "WARN: EEPROM fix basarisiz"
    else
      log "  CONFIRM_EEPROM_FIX=yes sudo bash $REMOTE_DIR/scripts/pi/fix-eeprom-usb-ssd.sh"
    fi
  fi
else
  log "WARN: rpi-eeprom-config yok"
fi

# SSH: password auth + zayiflik
if [[ -f /etc/ssh/sshd_config ]]; then
  if grep -Eiq '^\s*PasswordAuthentication\s+yes' /etc/ssh/sshd_config; then
    log "WARN: SSH PasswordAuthentication=yes — key ekleyip kapat"
  fi
fi
if [[ -f "$HOME/.ssh/authorized_keys" ]] && [[ -s "$HOME/.ssh/authorized_keys" ]]; then
  ok "SSH authorized_keys mevcut"
else
  log "WARN: ~/.ssh/authorized_keys bos — Mac'ten ssh-copy-id yap, sonra passwd + PasswordAuthentication no"
fi

# cloud-init ilk boot materyalini boot partition'dan sil (fiziksel erisim riski)
for boot in /boot/firmware /boot; do
  if [[ -f "$boot/user-data" ]]; then
    run_root() { if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
    for firstboot_file in user-data network-config userconf ssh; do
      if [[ -e "$boot/$firstboot_file" ]]; then
        run_root shred -u "$boot/$firstboot_file" 2>/dev/null || run_root rm -f "$boot/$firstboot_file"
      fi
    done
    log "OK: $boot cloud-init ilk boot dosyalari silindi"
  fi
done

# Legacy SD
if [[ -b /dev/mmcblk0p2 ]]; then
  parttype="$(lsblk -no PARTTYPE /dev/mmcblk0p2 2>/dev/null || true)"
  if [[ "$parttype" == "0x0" || "$parttype" == "0" || -z "$parttype" ]]; then
    # bos veya unknown — blkid ile bak
    if blkid /dev/mmcblk0p2 >/dev/null 2>&1; then
      log "WARN: legacy SD rootfs hala ext4 — neutralize et:"
      log "  CONFIRM=yes sudo bash $REMOTE_DIR/scripts/pi/neutralize-legacy-sd-root.sh"
      if [[ "$CONFIRM_NEUTRALIZE" == "yes" ]]; then
        CONFIRM=yes bash "$REMOTE_DIR/scripts/pi/neutralize-legacy-sd-root.sh"
      fi
    else
      ok "legacy SD root etkisiz veya bos"
    fi
  else
    log "WARN: mmcblk0p2 PARTTYPE=$parttype — neutralize onerilir"
  fi
fi

log "Tamamlandi. Sonraki: deploy + smoke + passwd"
