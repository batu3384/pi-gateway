#!/usr/bin/env bash
# macOS'ta MBR disk imzasindan Raspberry Pi PARTUUID uretir.
set -euo pipefail

mbr_partuuid_from_raw_file() {
  local raw="$1" part_no="$2" bytes b1 b2 b3 b4
  [[ -r "$raw" ]] || return 1
  [[ "$part_no" =~ ^[1-9][0-9]*$ ]] || return 1

  bytes="$(dd if="$raw" bs=1 skip=440 count=4 2>/dev/null | od -An -tu1)" || return 1
  read -r b1 b2 b3 b4 <<<"$bytes"
  [[ -n "${b1:-}" && -n "${b2:-}" && -n "${b3:-}" && -n "${b4:-}" ]] || return 1
  printf '%02x%02x%02x%02x-%02d\n' "$b4" "$b3" "$b2" "$b1" "$part_no"
}

mbr_partuuid_from_disk() {
  local disk="$1" part_no="$2" raw
  [[ "$disk" =~ ^/dev/disk[0-9]+$ ]] || return 1
  raw="/dev/r${disk#/dev/}"
  mbr_partuuid_from_raw_file "$raw" "$part_no"
}

# bootfs/cmdline.txt veya .bak-* icinden root PARTUUID
partuuid_from_cmdline_file() {
  local file="$1" uuid
  [[ -f "$file" ]] || return 1
  uuid="$(grep -oE 'root=PARTUUID=[0-9a-fA-F]{8}-[0-9]{2}' "$file" 2>/dev/null | head -1 | sed 's/^root=PARTUUID=//')"
  [[ -n "$uuid" ]] || return 1
  echo "$uuid"
}

sd_root_partuuid_from_bootfs() {
  local boot_dir="$1" f uuid
  for f in "${boot_dir}/cmdline.txt" "${boot_dir}/cmdline.txt.bak-pre-ssd-root" \
           "${boot_dir}/cmdline.txt.bak-hybrid-restore"; do
    if uuid="$(partuuid_from_cmdline_file "$f")"; then
      echo "$uuid"
      return 0
    fi
  done
  return 1
}

# diskutil: ilk Linux (FAT/EFI haric) partition -> MBR PARTUUID
mbr_root_partuuid_from_disk() {
  local disk="$1" line part_no part_id ptype uuid
  [[ "$disk" =~ ^/dev/disk[0-9]+$ ]] || return 1

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*[0-9]+: ]] || continue
    part_no="$(echo "$line" | sed -E 's/^[[:space:]]*([0-9]+):.*/\1/')"
    ptype="$(echo "$line" | awk '{print $3}')"
    [[ -n "$part_no" && -n "$ptype" ]] || continue
    echo "$ptype" | grep -qiE 'FAT|EFI|Windows' && continue
    echo "$ptype" | grep -qi 'Linux' || continue
    part_id="${disk}s${part_no}"
    diskutil info "$part_id" >/dev/null 2>&1 || continue
    if uuid="$(mbr_partuuid_from_disk "$disk" "$part_no" 2>/dev/null)"; then
      echo "$uuid"
      return 0
    fi
  done < <(diskutil list "$disk" 2>/dev/null)

  return 1
}

# Oncelik: cmdline (bootfs) -> Linux partition taramasi -> elle verilen fallback
detect_sd_root_partuuid() {
  local disk="$1" boot_dir="${2:-}" fallback="${3:-}"

  if [[ -n "$boot_dir" ]]; then
    if uuid="$(sd_root_partuuid_from_bootfs "$boot_dir")"; then
      echo "$uuid"
      return 0
    fi
  fi
  if uuid="$(mbr_root_partuuid_from_disk "$disk")"; then
    echo "$uuid"
    return 0
  fi
  [[ -n "$fallback" ]] && { echo "$fallback"; return 0; }
  return 1
}
