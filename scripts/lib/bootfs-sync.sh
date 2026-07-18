#!/usr/bin/env bash
# A mimarisi: SSD bootfs snapshot -> SD bootfs (firmware/kernel/initramfs)
# SD golden -> SSD repair icin ters yon de repair-cutover-bootfs.sh'ta
set -euo pipefail

BOOT_SYNC_EXCLUDES=(
  --exclude 'cmdline.txt'
  --exclude 'cmdline.txt.*'
  --exclude 'user-data'
  --exclude 'user-data.*'
  --exclude 'meta-data'
  --exclude 'network-config'
  --exclude 'userconf'
  --exclude 'ssh'
  --exclude '._*'
  --exclude '.Spotlight-V100'
  --exclude '.fseventsd'
)

bootfs_rsync_checksum_ok() {
  local src="$1" dst="$2"
  [[ -n "$(rsync -rnc --omit-dir-times "${BOOT_SYNC_EXCLUDES[@]}" "$src/" "$dst/")" ]] && return 1
  return 0
}

bootfs_snapshot_from_volume() {
  local src_boot="$1" stage="$2"
  rsync -a "${BOOT_SYNC_EXCLUDES[@]}" "$src_boot/" "$stage/"
  bootfs_rsync_checksum_ok "$src_boot" "$stage"
}

bootfs_apply_snapshot() {
  local stage="$1" dst_boot="$2"
  rsync -a "${BOOT_SYNC_EXCLUDES[@]}" "$stage/" "$dst_boot/"
  bootfs_rsync_checksum_ok "$stage" "$dst_boot"
}

verify_pi4_boot_archives() {
  local boot="$1"
  [[ -s "$boot/kernel8.img" ]] || return 1
  gzip -t "$boot/kernel8.img" >/dev/null 2>&1 || return 1
  command -v cpio >/dev/null 2>&1 || return 1
  [[ -s "$boot/initramfs8" ]] || return 1
  cpio -it < "$boot/initramfs8" >/dev/null 2>&1
}
