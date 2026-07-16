#!/usr/bin/env bash
# /mnt/ssd fstab satirini dogrular — silinirse veya yanlissa duzeltir
set -euo pipefail

MOUNT="/mnt/ssd"
LABEL="pi-data"
LOG_TAG="pi-gateway-fstab"

log() {
  logger -t "$LOG_TAG" "$*"
  echo "[ensure-fstab] $*"
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

root_disk() {
  findmnt -n -o SOURCE / | sed -E 's/p?[0-9]+$//; s/[0-9]+$//'
}

partition_id() {
  local part="$1"
  local id
  id="$(blkid -o value -s PARTUUID "$part" 2>/dev/null || true)"
  if [[ -n "$id" ]]; then
    echo "PARTUUID=${id}"
    return 0
  fi
  id="$(blkid -o value -s UUID "$part" 2>/dev/null || true)"
  [[ -n "$id" ]] || return 1
  echo "UUID=${id}"
}

find_ssd_partition() {
  local by_label root base dev part existing_id expected_part
  by_label="$(blkid -L "$LABEL" 2>/dev/null || true)"
  if [[ -n "$by_label" && -b "$by_label" ]]; then
    echo "$by_label"
    return 0
  fi

  existing_id="$(fstab_entry_id || true)"
  if [[ -n "$existing_id" ]]; then
    expected_part="$(blkid "$existing_id" -o device 2>/dev/null || true)"
    if [[ -n "$expected_part" && -b "$expected_part" ]]; then
      echo "$expected_part"
      return 0
    fi
    log "WARN: fstab kimligi mevcut diski gostermiyor — yeniden aranacak"
  fi

  root="$(root_disk)"
  for dev in /dev/sd? /dev/nvme?n?; do
    [[ -b "$dev" ]] || continue
    base="$(basename "$dev")"
    [[ "$root" == *"$base"* ]] && continue
    if [[ "$dev" == /dev/nvme* ]]; then
      part="${dev}p1"
    else
      part="${dev}1"
    fi
    [[ -b "$part" ]] || continue
    blkid -o value -s LABEL "$part" 2>/dev/null | grep -qx "$LABEL" || continue
    blkid -o value -s TYPE "$part" 2>/dev/null | grep -qx ext4 || continue
    echo "$part"
    return 0
  done
  return 1
}

fstab_entry_id() {
  awk -v mnt="$MOUNT" '$2 == mnt {print $1; exit}' /etc/fstab 2>/dev/null
}

fstab_entry_matches() {
  local part="$1"
  local current expected
  expected="$(partition_id "$part")" || return 1
  current="$(fstab_entry_id || true)"
  [[ -n "$current" && "$current" == "$expected" ]]
}

write_fstab_entry() {
  local part="$1"
  local entry id_spec

  if fstab_entry_matches "$part"; then
    log "fstab OK ($MOUNT -> $part)"
    return 0
  fi

  id_spec="$(partition_id "$part")" || {
    log "WARN: partition kimligi alinamadi: $part"
    return 1
  }

  entry="${id_spec} ${MOUNT} ext4 defaults,noatime,nofail,x-systemd.device-timeout=30 0 2"
  if fstab_entry_id >/dev/null 2>&1; then
    log "fstab guncelleniyor (eski satir degisiyor)"
    run_root sed -i.bak "/[[:space:]]${MOUNT//\//\\/}[[:space:]]/d" /etc/fstab
  else
    log "fstab ekleniyor: $entry"
  fi
  run_root bash -c "echo '$entry' >> /etc/fstab"
  run_root systemctl daemon-reload 2>/dev/null || true
  log "fstab guncellendi"
}

main() {
  local part
  part="$(find_ssd_partition)" || {
    log "USB veri diski yok — fstab atlandi"
    exit 0
  }
  write_fstab_entry "$part"
}

main "$@"
