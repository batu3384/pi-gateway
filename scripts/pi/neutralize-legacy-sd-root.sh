#!/usr/bin/env bash
# Pi: Eski SD rootfs'i (mmcblk0p2) boot edilemez hale getir — PARTUUID carpismasi onleme
# YALNIZCA root zaten SSD'deyken calistir.
# Kullanim: CONFIRM=yes sudo bash scripts/pi/neutralize-legacy-sd-root.sh
set -euo pipefail

CONFIRM="${CONFIRM:-}"
LOG_TAG="pi-gateway-neutralize-sd"

log() { echo "[neutralize-sd] $*"; logger -t "$LOG_TAG" "$*" 2>/dev/null || true; }
die() { log "HATA: $*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "root gerekli"
[[ "$CONFIRM" == "yes" ]] || die "CONFIRM=yes gerekli"

root_src="$(findmnt -n -o SOURCE / || true)"
[[ -n "$root_src" ]] || die "root mount okunamadi"
echo "$root_src" | grep -q mmcblk && die "root hala SD ($root_src) — once ssd-root boot dogrula"
echo "$root_src" | grep -qE '/dev/sd|/dev/nvme|/dev/vd' || {
  log "WARN: root beklenmedik cihaz: $root_src — devam (ssd-root varsayimi)"
}

SD_PART="/dev/mmcblk0p2"
SD_DISK="/dev/mmcblk0"
[[ -b "$SD_PART" ]] || die "$SD_PART yok"
[[ -b "$SD_DISK" ]] || die "$SD_DISK yok"

# Bootfs (p1) mount ise unmount etme — sadece tip degistir
if findmnt -n "$SD_PART" >/dev/null 2>&1; then
  die "$SD_PART mount durumda — once unmount"
fi

if command -v sfdisk >/dev/null 2>&1; then
  # util-linux: sfdisk --part-type <disk> <partnum> <type>
  log "mmcblk0 partition 2 tipini 0 (empty) yapiyor..."
  before="$(sfdisk --part-type "$SD_DISK" 2 2>/dev/null || true)"
  sfdisk --part-type "$SD_DISK" 2 0 || die "sfdisk --part-type basarisiz"
  after="$(sfdisk --part-type "$SD_DISK" 2 2>/dev/null || true)"
  log "part-type: ${before:-?} -> ${after:-0}"
  [[ "$after" == "0" || "$after" == "0x0" || "$after" == "00" ]] || \
    log "WARN: part-type dogrulamasi belirsiz ($after) — lsblk ile kontrol et"
else
  log "sfdisk yok — mmcblk0p2 superblock wipe (1MB)"
  dd if=/dev/zero of="$SD_PART" bs=1M count=1 status=none || die "dd basarisiz"
fi

sync
partprobe "$SD_DISK" 2>/dev/null || true
log "OK: legacy SD root etkisiz. bootfs (p1) dokunulmadi."
log "Dogrula: lsblk -o NAME,TYPE,FSTYPE,PARTTYPE /dev/mmcblk0"
