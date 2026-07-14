#!/usr/bin/env bash
# SD boot + USB SSD veri diski — ilk acilista veya elle calistirilir.
set -euo pipefail

MARKER="/mnt/ssd/.pi-gateway-initialized"
MOUNT="/mnt/ssd"
LABEL="pi-data"
DATA_ROOT="${MOUNT}/pi-gateway-data"
LOG_TAG="[pi-ssd-data]"

log() { echo "$LOG_TAG $*"; }
die() { log "HATA: $*"; exit 1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "root gerekli: sudo $0"
}

root_disk() {
  findmnt -n -o SOURCE / | sed -E 's/p?[0-9]+$//; s/[0-9]+$//'
}

find_usb_data_disk() {
  local root base dev
  root="$(root_disk)"
  for dev in /dev/sd? /dev/sd?? /dev/nvme?n?; do
    [[ -b "$dev" ]] || continue
    base="$(basename "$dev")"
    [[ "$root" == *"$base"* ]] && continue
    echo "$dev"
    return 0
  done
  return 1
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
  local disk="$1" part="$2"

  if blkid -o value -s TYPE "$part" 2>/dev/null | grep -q ext4; then
    local current_label
    current_label="$(blkid -o value -s LABEL "$part" 2>/dev/null || true)"
    if [[ "$current_label" != "$LABEL" ]]; then
      e2label "$part" "$LABEL" || true
    fi
    log "Mevcut ext4 partition kullaniliyor: $part ($LABEL)"
    return 0
  fi

  log "SSD hazirlaniyor: $disk -> tek ext4 partition ($LABEL)"
  wipefs -a "$disk" || true
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

  local entry="PARTUUID=${uuid} ${MOUNT} ext4 defaults,noatime,nofail,x-systemd.device-timeout=30 0 2"
  if grep -qF "$MOUNT" /etc/fstab 2>/dev/null; then
    log "fstab guncelleniyor"
    sed -i.bak "/[[:space:]]${MOUNT//\//\\/}[[:space:]]/d" /etc/fstab
  fi
  echo "$entry" >> /etc/fstab
  log "fstab: $entry"
}

prepare_data_tree() {
  local user="${PI_USER:-batu}"
  local remote="${REMOTE_DIR:-/home/${user}/pi-gateway}"

  mkdir -p \
    "${DATA_ROOT}/adguard/work" \
    "${DATA_ROOT}/uptime-kuma" \
    "${DATA_ROOT}/docker-volumes" \
    "${DATA_ROOT}/logs" \
    "${DATA_ROOT}/forgejo" \
    "${DATA_ROOT}/syncthing" \
    "${DATA_ROOT}/restic" \
    "${DATA_ROOT}/projects" \
    "${DATA_ROOT}/backups" \
    "${DATA_ROOT}/redis" \
    "${DATA_ROOT}/n8n" \
    "${DATA_ROOT}/crowdsec"

  chown -R "${user}:${user}" "$DATA_ROOT"

  if [[ -d "$remote" ]]; then
    mkdir -p "$remote"
    if [[ ! -L "${remote}/data" ]]; then
      if [[ -d "${remote}/data" && ! -L "${remote}/data" ]]; then
        if [[ -z "$(ls -A "${remote}/data" 2>/dev/null)" ]]; then
          rmdir "${remote}/data" 2>/dev/null || true
        else
          log "Mevcut data tasinyor -> ${DATA_ROOT}"
          rsync -a "${remote}/data/" "${DATA_ROOT}/" || true
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
  local disk part
  disk="$(find_usb_data_disk)" || die "USB veri diski bulunamadi (SSD takili mi?)"
  part="$(partition_for_disk "$disk")"

  if [[ -f "$MARKER" ]] && mountpoint -q "$MOUNT"; then
    log "Zaten hazir ($MARKER) — symlink kontrol"
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
