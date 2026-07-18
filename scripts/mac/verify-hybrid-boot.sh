#!/usr/bin/env bash
# Mac: hybrid bootfs dogrulama (SD root, SSD veri hazirligi)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/bootfs-sync.sh
source "$SCRIPT_DIR/../lib/bootfs-sync.sh"
# shellcheck source=../lib/mbr-partuuid.sh
source "$SCRIPT_DIR/../lib/mbr-partuuid.sh"

log() { echo "[verify-hybrid] $*"; }
die() { log "HATA: $*"; exit 1; }
ok() { log "OK: $*"; }

[[ "$(uname)" == "Darwin" ]] || die "Sadece macOS"

PI_SD_DISK="${PI_SD_DISK:-}"
PI_SSD_DISK="${PI_SSD_DISK:-}"
SD_ROOT_PARTUUID="${SD_ROOT_PARTUUID:-}"

[[ -n "$PI_SD_DISK" ]] || die "PI_SD_DISK zorunlu"

mount_bootfs() {
  local disk="$1" part mp
  part="${disk}s1"
  diskutil mount "$part" >/dev/null 2>&1 || true
  sleep 1
  mp="$(diskutil info "$part" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2; exit}')"
  [[ -n "$mp" && -f "$mp/cmdline.txt" ]] || return 1
  echo "$mp"
}

BOOT_SD="$(mount_bootfs "$PI_SD_DISK")" || die "SD bootfs yok"
SD_ROOT_PARTUUID="$(detect_sd_root_partuuid "$PI_SD_DISK" "$BOOT_SD" "${SD_ROOT_PARTUUID}")" \
  || die "SD root PARTUUID okunamadi"
verify_pi4_boot_archives "$BOOT_SD" || die "SD kernel/initramfs bozuk"
ok "SD boot archive"

SD_CMD="$(tr -d '\n' < "$BOOT_SD/cmdline.txt")"
echo "$SD_CMD" | grep -q "root=PARTUUID=${SD_ROOT_PARTUUID}" || die "SD root PARTUUID yanlis (beklenen ${SD_ROOT_PARTUUID})"
echo "$SD_CMD" | grep -q 'usb-storage.quirks=' || die "quirks yok"
echo "$SD_CMD" | grep -qE 'rootdelay=[0-9]+' && die "rootdelay hybrid SD root'ta olmamali"
echo "$SD_CMD" | grep -qE '(^| )resize( |$)' && die "resize hybrid SD root'ta olmamali"
ok "SD cmdline hybrid"

[[ -f "$BOOT_SD/ssh" ]] || die "SD ssh yok"
[[ -f "$BOOT_SD/user-data" ]] || die "SD user-data yok"
grep -q 'pi-ssd-data.service' "$BOOT_SD/user-data" || die "user-data SSD unit yok"
grep -q 'PI_SSD_CONFIRM_FORMAT=yes' "$BOOT_SD/user-data" || die "user-data format onayi yok"
ok "SD cloud-init SSD setup"

if [[ -n "$PI_SSD_DISK" ]]; then
  info="$(diskutil list "$PI_SSD_DISK" 2>/dev/null || true)"
  if echo "$info" | grep -qiE 'Linux|bootfs|Windows_FAT_32'; then
    die "SSD hala Pi OS partition — CONFIRM_WIPE_SSD=yes ile restore-hybrid calistir"
  fi
  ok "SSD bos veya veri diski hazir"
fi

log "Hybrid bootfs dogrulama gecti"
