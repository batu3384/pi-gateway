#!/usr/bin/env bash
# SD boot + SSD root cmdline olusturma (resize/kernel parametreleri korunur)
set -euo pipefail

ROOTDELAY="${PI_ROOTDELAY:-25}"
_USB_QUIRK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/usb-quirk.sh"
# shellcheck source=usb-quirk.sh
source "$_USB_QUIRK_LIB"

normalize_cmdline_parts() {
  local line="$1"
  line=$(echo "$line" | tr '\n' ' ')
  line=$(echo "$line" | sed -E \
    's/usb-storage\.quirks=[^ ]* ?//g;
     s/usbcore\.quirks=[^ ]* ?//g;
     s/usbcore\.autosuspend=[^ ]* ?//g;
     s/rootdelay=[0-9]+ ?//g;
     s/(^| )quiet( |$)/ /g;
     s/(^| )splash( |$)/ /g;
     s/  +/ /g; s/^ +| +$//g')
  echo "$line"
}

build_ssd_root_cmdline() {
  local quirk="$1"
  local base_line="$2"
  local parts
  parts="$(normalize_cmdline_parts "$base_line")"
  echo "usb-storage.quirks=$(normalize_storage_quirk "$quirk") usbcore.quirks=$(usbcore_quirk_from_storage "$quirk") usbcore.autosuspend=-1 rootdelay=${ROOTDELAY} ${parts}"
}

cmdline_has_resize() {
  grep -qE '(^| )resize( |$)' <<<"$1"
}

sync_boot_partition_cloud_init() {
  local src_boot="$1"
  local dst_boot="$2"
  local f
  for f in user-data network-config userconf; do
    [[ -f "$src_boot/$f" ]] || return 1
  done
  for f in user-data network-config userconf ssh; do
    if [[ -f "$src_boot/$f" ]]; then
      cp "$src_boot/$f" "$dst_boot/$f"
    fi
  done
  [[ -f "$src_boot/ssh" ]] || touch "$dst_boot/ssh"
}
