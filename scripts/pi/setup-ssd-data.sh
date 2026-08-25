#!/usr/bin/env bash
# SD boot + USB SSD veri diski — ilk acilista veya elle calistirilir.
set -euo pipefail
MARKER="/mnt/ssd/.pi-gateway-initialized"
MOUNT="/mnt/ssd"
LABEL="pi-data"
DATA_ROOT="${MOUNT}/pi-gateway-data"
LOG_TAG="[pi-ssd-data]"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo "$LOG_TAG $*"; }
die() { log "HATA: $*"; exit 1; }
require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "root gerekli: sudo $0"
}
root_disk() {
  findmnt -n -o SOURCE / | sed -E 's/p?[0-9]+$//; s/[0-9]+$//'
}
find_usb_data_disk() {
  local root base dev candidates=()
  root="$(root_disk)"
  if [[ -n "${PI_SSD_DISK:-}" ]]; then
    [[ -b "$PI_SSD_DISK" ]] || die "PI_SSD_DISK gecersiz: $PI_SSD_DISK"
    base="$(basename "$PI_SSD_DISK")"
    [[ "$root" == *"$base"* ]] && die "PI_SSD_DISK root diski gosteriyor: $PI_SSD_DISK"
    echo "$PI_SSD_DISK"
    return 0
  fi
  # Yalnizca whole-disk node'lari (sda1 gibi partition'lari sd? glob'i karistirir)
  for dev in /dev/sd[a-z]; do
    [[ -b "$dev" ]] || continue
    base="$(basename "$dev")"
    [[ "$root" == *"$base"* ]] && continue
    candidates+=("$dev")
  done
  for dev in /dev/nvme*n*; do
    [[ -b "$dev" ]] || continue
    [[ "$dev" =~ p[0-9]+$ ]] && continue
    base="$(basename "$dev")"
    [[ "$root" == *"$base"* ]] && continue
    candidates+=("$dev")
  done
  if [[ ${#candidates[@]} -eq 0 ]]; then
    return 1
  fi
  if [[ ${#candidates[@]} -gt 1 ]]; then
    die "Birden fazla USB disk: ${candidates[*]} — PI_SSD_DISK=/dev/sdX belirt"
  fi
  echo "${candidates[0]}"
}
disk_size_gb() {
  local dev="$1"
  lsblk -bdno SIZE "$dev" 2>/dev/null | awk '{printf "%d", ($1+1073741823)/1073741824}'
}
partition_for_disk() {
  local dev="$1"
  if [[ "$dev" == /dev/nvme* ]]; then
    echo "${dev}p1"
  else
    echo "${dev}1"
  fi
}
ensure_ext4_partition() {
  local disk="$1" part="$2" size_gb
  if blkid -o value -s TYPE "$part" 2>/dev/null | grep -q ext4; then
    local current_label
    current_label="$(blkid -o value -s LABEL "$part" 2>/dev/null || true)"
    if [[ "$current_label" != "$LABEL" ]]; then
      e2label "$part" "$LABEL" || true
    fi
    log "Mevcut ext4 partition kullaniliyor: $part ($LABEL)"
    echo "$part"
    return 0
  fi
  size_gb="$(disk_size_gb "$disk")"
  if [[ -z "$size_gb" || "$size_gb" -lt 8 ]]; then
    die "Disk cok kucuk veya okunamadi (${size_gb:-?}GB): $disk"
  fi
  if findmnt -n "$part" "$disk" 2>/dev/null | grep -q .; then
    die "Disk/partition mount durumda — format iptal: $disk $part"
  fi
  if [[ "${PI_SSD_CONFIRM_FORMAT:-}" != "yes" ]]; then
    die "Yeni format icin PI_SSD_CONFIRM_FORMAT=yes gerekli (disk: $disk, ~${size_gb}GB)"
  fi
  log "SSD hazirlaniyor: $disk (~${size_gb}GB) -> tek ext4 partition ($LABEL)"
  wipefs -a "$disk"
  parted -s "$disk" mklabel msdos
  parted -s "$disk" mkpart primary ext4 4MiB 100%
  partprobe "$disk" || true
  sleep 2
  part="$(partition_for_disk "$disk")"
  [[ -b "$part" ]] || die "Partition olusmadi: $part"
  mkfs.ext4 -F -L "$LABEL" "$part"
  echo "$part"
}
mount_ssd() {
  local part="$1"
  mkdir -p "$MOUNT"
  if mountpoint -q "$MOUNT"; then
    log "$MOUNT zaten mount"
    return 0
  fi
  mount "$part" "$MOUNT"
  log "Mount OK: $part -> $MOUNT"
}
ensure_fstab() {
  local part="$1"
  local uuid
  uuid="$(blkid -o value -s PARTUUID "$part")"
  [[ -n "$uuid" ]] || die "PARTUUID alinamadi: $part"
  local entry="PARTUUID=${uuid} ${MOUNT} ext4 defaults,noatime,nodiscard,nofail,x-systemd.device-timeout=30 0 2"
  if grep -qF "$MOUNT" /etc/fstab 2>/dev/null; then
    log "fstab guncelleniyor"
    sed -i.bak "/[[:space:]]${MOUNT//\//\\/}[[:space:]]/d" /etc/fstab
  fi
  echo "$entry" >> /etc/fstab
  log "fstab: $entry"
}
prepare_data_tree() {
  local user="${PI_USER:-pi}"
  local remote="${REMOTE_DIR:-/home/${user}/pi-gateway}"
  mkdir -p \
    "${DATA_ROOT}/adguard/work" \
    "${DATA_ROOT}/uptime-kuma" \
    "${DATA_ROOT}/docker-volumes" \
    "${DATA_ROOT}/logs" \
    "${DATA_ROOT}/netalertx" \
    "${DATA_ROOT}/restic" \
    "${DATA_ROOT}/backups" \
    "${DATA_ROOT}/n8n" \
    "${DATA_ROOT}/crowdsec" \
    "${MOUNT}/.disk-probe"
  chown -R "${user}:${user}" "$DATA_ROOT"
  if [[ -d "$remote" ]]; then
    mkdir -p "$remote"
    if [[ ! -L "${remote}/data" ]]; then
      if [[ -d "${remote}/data" && ! -L "${remote}/data" ]]; then
        if [[ -z "$(ls -A "${remote}/data" 2>/dev/null)" ]]; then
          rmdir "${remote}/data" 2>/dev/null || true
        else
          log "Mevcut data tasinyor -> ${DATA_ROOT}"
          rsync -a "${remote}/data/" "${DATA_ROOT}/"
          rm -rf "${remote}/data"
        fi
      fi
      ln -sfn "$DATA_ROOT" "${remote}/data"
      chown -h "${user}:${user}" "${remote}/data"
      log "Symlink: ${remote}/data -> ${DATA_ROOT}"
    fi
  else
    log "UYARI: ${remote} henuz yok (make install sonrasi symlink tekrar kontrol edilebilir)"
  fi
}
write_health_hint() {
  {
    echo "Pi Gateway veri diski"
    echo "Mount: ${MOUNT}"
    echo "Label: ${LABEL}"
    echo "Kullanim: AdGuard, Uptime Kuma, Docker volume, loglar"
    echo "OS: SD kart (mmcblk0) uzerinde kalir"
  } > "${MOUNT}/README.txt"
}
main() {
  require_root
  REMOTE_DIR="${REMOTE_DIR:-/home/${PI_USER:-pi}/pi-gateway}"
  # shellcheck source=../lib/env-file.sh
  source "$SCRIPT_DIR/../lib/env-file.sh"
  read_remote_dotenv || die ".env dotenv parser hatasi"
  _SSD_REMOTE_DIR="$REMOTE_DIR"
  REMOTE_DIR="$_SSD_REMOTE_DIR"
  STORAGE_TYPE="${STORAGE_TYPE:-hybrid}"
  if [[ "$STORAGE_TYPE" == "ssd-root" || "$STORAGE_TYPE" == "ssd" ]]; then
    log "STORAGE_TYPE=${STORAGE_TYPE} — ayri veri diski kurulumu gerekmez (root=SSD)"
    exit 0
  fi
  local disk part mounted_part
  if mountpoint -q "$MOUNT" 2>/dev/null; then
    mounted_part="$(findmnt -n -o SOURCE "$MOUNT" 2>/dev/null || true)"
    if [[ -n "$mounted_part" ]] && blkid -o value -s TYPE "$mounted_part" 2>/dev/null | grep -q ext4; then
      log "SSD zaten mount: $mounted_part -> $MOUNT"
      ensure_fstab "$mounted_part"
      prepare_data_tree
      write_health_hint
      [[ -f "$MARKER" ]] || touch "$MARKER"
      chmod 644 "$MARKER"
      log "Tamamlandi (mevcut mount)"
      exit 0
    fi
  fi
  disk="$(find_usb_data_disk)" || die "USB veri diski bulunamadi (SSD takili mi?)"
  part="$(partition_for_disk "$disk")"
  if [[ -f "$MARKER" ]]; then
    log "Zaten hazir ($MARKER) — fstab + symlink kontrol"
    mount_ssd "$part" || die "Hazir SSD mount edilemedi: $part"
    mountpoint -q "$MOUNT" || die "Hazir SSD mount probe basarisiz: $MOUNT"
    mounted_part="$(findmnt -n -o SOURCE "$MOUNT" 2>/dev/null || true)"
    [[ "$mounted_part" == "$part" ]] || die "Yanlis SSD mount: beklenen $part, bulunan ${mounted_part:-yok}"
    ensure_fstab "$part"
    prepare_data_tree
    exit 0
  fi
  if ! blkid -o value -s TYPE "$part" 2>/dev/null | grep -q ext4; then
    part="$(ensure_ext4_partition "$disk" "$part")"
  fi
  mount_ssd "$part"
  ensure_fstab "$part"
  prepare_data_tree
  write_health_hint
  touch "$MARKER"
  chmod 644 "$MARKER"
  log "Tamamlandi. Veri diski: $MOUNT ($part)"
}
main "$@"
