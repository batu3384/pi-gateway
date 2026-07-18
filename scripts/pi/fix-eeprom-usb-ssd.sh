#!/usr/bin/env bash
# Pi EEPROM: JMicron USB SSD kesfi (A mimarisi = SD boot + SSD root)
# B mimarisi (tam USB boot): ARCH=B BOOT_ORDER=0xf14
set -euo pipefail

ARCH="${ARCH:-A}"
CONFIRM_EEPROM_FIX="${CONFIRM_EEPROM_FIX:-no}"
LOG_TAG="pi-gateway-eeprom-fix"

log() { echo "[eeprom-fix] $*"; logger -t "$LOG_TAG" "$*" 2>/dev/null || true; }
die() { log "HATA: $*"; exit 1; }

command -v rpi-eeprom-config >/dev/null 2>&1 || die "rpi-eeprom-config yok"

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

if [[ "$ARCH" == "B" ]]; then
  BOOT_ORDER="0xf14"
else
  # Raspberry Pi resmi SD profili: SD first, then USB mass storage.
  BOOT_ORDER="0xf41"
fi

want=(
  "BOOT_ORDER=${BOOT_ORDER}"
  "USB_MSD_PWR_OFF_TIME=0"
  "USB_MSD_DISCOVER_TIMEOUT=25000"
  "USB_MSD_STARTUP_DELAY=5000"
)

current="$(run_root rpi-eeprom-config 2>/dev/null || true)"
missing=()
for kv in "${want[@]}"; do
  key="${kv%%=*}"
  expected="${kv#*=}"
  actual="$(echo "$current" | awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}')"
  if [[ "$actual" != "$expected" ]]; then
    missing+=("$kv")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  log "EEPROM zaten uygun (ARCH=$ARCH)"
  run_root rpi-eeprom-config | grep -E 'BOOT_ORDER|USB_MSD' || true
  exit 0
fi

log "Eksik EEPROM ayarlari (${#missing[@]}):"
printf '  %s\n' "${missing[@]}"

if [[ "$CONFIRM_EEPROM_FIX" != "yes" ]]; then
  log "Uygulamak icin: CONFIRM_EEPROM_FIX=yes sudo bash $0"
  exit 1
fi

tmp="$(mktemp)"
run_root rpi-eeprom-config >"$tmp"
for kv in "${want[@]}"; do
  key="${kv%%=*}"
  val="${kv#*=}"
  if grep -q "^${key}=" "$tmp"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$tmp"
  else
    echo "${key}=${val}" >>"$tmp"
  fi
done
run_root rpi-eeprom-config --apply "$tmp"
rm -f "$tmp"

log "EEPROM guncellendi — reboot gerekli (ARCH=$ARCH BOOT_ORDER=$BOOT_ORDER)"
run_root rpi-eeprom-config | grep -E 'BOOT_ORDER|USB_MSD' || true
