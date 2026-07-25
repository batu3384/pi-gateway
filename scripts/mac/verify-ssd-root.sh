#!/usr/bin/env bash
# Mac: SD cmdline root= SSD root PARTUUID ile eslesmeli; eski SD root'a bakmamali
#
# Kullanim (diskler takili):
#   ./scripts/mac/verify-ssd-root.sh
#   PI_SD_DISK=/dev/disk47 PI_SSD_DISK=/dev/disk48 ./scripts/mac/verify-ssd-root.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/mbr-partuuid.sh
source "$SCRIPT_DIR/../lib/mbr-partuuid.sh"
# shellcheck source=../lib/bootfs-sync.sh
source "$SCRIPT_DIR/../lib/bootfs-sync.sh"

PI_SD_DISK="${PI_SD_DISK:-}"
PI_SSD_DISK="${PI_SSD_DISK:-}"
VERIFY_STRICT_SSD_BOOTFS="${VERIFY_STRICT_SSD_BOOTFS:-${STRICT_SSD_BOOTFS:-no}}"
SKIP_MBR="${SKIP_MBR:-no}"

if [[ "$(id -u)" -ne 0 ]]; then
  SKIP_MBR=yes
fi

log() { echo "[verify-ssd-root] $*"; }
die() { log "HATA: $*"; exit 1; }
ok() { log "OK: $*"; }

[[ "$(uname)" == "Darwin" ]] || die "Sadece macOS"

disk_size_gb() {
  diskutil info "$1" 2>/dev/null | awk -F': *' '/Disk Size/ {print $2}' | grep -oE '[0-9]+' | head -1
}

mount_point_of() {
  diskutil info "$1" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2; exit}'
}

mount_bootfs() {
  local disk="$1" part="${1}s1" mp
  diskutil mount "$part" >/dev/null 2>&1 || true
  sleep 1
  mp="$(mount_point_of "$part")"
  [[ -n "$mp" && "$mp" != "Not applicable" && -f "$mp/cmdline.txt" ]] || return 1
  echo "$mp"
}

cmdline_root() {
  grep -oE 'root=[^ ]+' "$1/cmdline.txt" 2>/dev/null | head -1
}

verify_pi4_boot_archives_or_die() {
  local boot="$1" label="$2" strict="${3:-yes}"
  if verify_pi4_boot_archives "$boot"; then
    ok "Pi 4 boot archive integrity: $label ($boot)"
    return 0
  fi
  if [[ "$strict" == "yes" ]]; then
    die "Pi 4 boot archive bozuk: $label ($boot)"
  fi
  log "WARN: Pi 4 boot archive bozuk (A mimarisinde SD yeterli): $label ($boot)"
}

find_by_size() {
  local min_gb="$1" max_gb="$2" disk gb
  while read -r disk; do
    [[ -z "$disk" ]] && continue
    diskutil info "$disk" 2>/dev/null | grep -q "Internal" && continue
    gb="$(disk_size_gb "$disk")"
    [[ -n "$gb" ]] || continue
    if [[ "$gb" -ge "$min_gb" && "$gb" -le "$max_gb" ]]; then
      echo "$disk"
    fi
  done < <(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+ \(external/ {print $1}' | tr -d ':')
}

pick_disk() {
  local label="$1" min_gb="$2" max_gb="$3" forced="$4" info gb
  local -a cands=()
  local d
  if [[ -n "$forced" ]]; then
    [[ -b "$forced" ]] || die "$label disk yok: $forced"
    info="$(diskutil info "$forced" 2>/dev/null)" || die "$label diskutil info basarisiz: $forced"
    echo "$info" | grep -qE '^   Whole: +Yes$' || die "$label whole disk degil: $forced"
    echo "$info" | grep -qE '^   Device Location: +External$' || die "$label external disk degil: $forced"
    echo "$info" | grep -qE '^   Media Read-Only: +No$' || die "$label disk salt-okunur: $forced"
    gb="$(disk_size_gb "$forced")"
    [[ -n "$gb" && "$gb" -ge "$min_gb" && "$gb" -le "$max_gb" ]] || \
      die "$label boyutu gecersiz: ${gb:-?}GB"
    echo "$forced"
    return 0
  fi
  while IFS= read -r d; do
    [[ -n "$d" ]] && cands+=("$d")
  done < <(find_by_size "$min_gb" "$max_gb")
  [[ ${#cands[@]} -eq 1 ]] || die "$label: ${#cands[@]} aday — PI_SD_DISK/PI_SSD_DISK kullan (${cands[*]:-yok})"
  echo "${cands[0]}"
}

SD_DISK="$(pick_disk SD 8 512 "${PI_SD_DISK:-}")"
SSD_DISK="$(pick_disk SSD 32 4096 "${PI_SSD_DISK:-}")"
[[ "$SD_DISK" != "$SSD_DISK" ]] || die "SD ve SSD ayni"

log "SD=$SD_DISK ($(disk_size_gb "$SD_DISK")GB) SSD=$SSD_DISK ($(disk_size_gb "$SSD_DISK")GB)"

BOOT_SD="$(mount_bootfs "$SD_DISK")" || die "SD bootfs mount edilemedi"
BOOT_SSD="$(mount_bootfs "$SSD_DISK")" || die "SSD bootfs mount edilemedi"

# Mount Point diskutil ile esle (space iceren volume adlari guvenli)
sd_mp="$(mount_point_of "${SD_DISK}s1")"
ssd_mp="$(mount_point_of "${SSD_DISK}s1")"
[[ "$sd_mp" == "$BOOT_SD" ]] || die "SD bootfs path uyusmuyor: $BOOT_SD vs $sd_mp"
[[ "$ssd_mp" == "$BOOT_SSD" ]] || die "SSD bootfs path uyusmuyor: $BOOT_SSD vs $ssd_mp"
ok "SD bootfs = $BOOT_SD ($(basename "$SD_DISK"))"
ok "SSD bootfs = $BOOT_SSD ($(basename "$SSD_DISK"))"
verify_pi4_boot_archives_or_die "$BOOT_SD" SD yes
if [[ "$VERIFY_STRICT_SSD_BOOTFS" == "yes" ]]; then
  verify_pi4_boot_archives_or_die "$BOOT_SSD" SSD yes
else
  verify_pi4_boot_archives_or_die "$BOOT_SSD" SSD no
fi
SD_ROOT="$(cmdline_root "$BOOT_SD")"
SSD_ROOT="$(cmdline_root "$BOOT_SSD")"
[[ -n "$SD_ROOT" ]] || die "SD cmdline root= yok"
[[ -n "$SSD_ROOT" ]] || die "SSD cmdline root= yok"
[[ "$SD_ROOT" == root=PARTUUID=* ]] || die "SD root PARTUUID degil: $SD_ROOT"
[[ "$SSD_ROOT" == root=PARTUUID=* ]] || die "SSD root PARTUUID degil: $SSD_ROOT"

# Asil kontrat: SD, SSD root'a bakmali
[[ "$SD_ROOT" == "$SSD_ROOT" ]] || die "SD root ($SD_ROOT) != SSD root ($SSD_ROOT)"
ok "SD ve SSD ayni root: $SD_ROOT"

# Bak dosyasi zorunlu: esit cmdline tek basina false-green olmamali.
[[ -f "$BOOT_SD/cmdline.txt.bak-pre-ssd-root" ]] || die "SD cutover backup yok"
OLD="$(grep -oE 'root=[^ ]+' "$BOOT_SD/cmdline.txt.bak-pre-ssd-root" | head -1 || true)"
[[ -n "$OLD" && "$OLD" != "$SD_ROOT" ]] || die "SD root hala bak-pre ile ayni veya backup gecersiz: ${OLD:-yok}"
ok "eski SD root farkli: $OLD -> $SD_ROOT"

SSD_PARTUUID="$(mbr_partuuid_from_disk "$SSD_DISK" 2)" || SSD_PARTUUID=""
EXPECTED_ROOT="root=PARTUUID=${SSD_PARTUUID}"
if [[ -n "$SSD_PARTUUID" ]]; then
  [[ "$SSD_ROOT" == "$EXPECTED_ROOT" ]] || die "SSD cmdline root ($SSD_ROOT) gercek SSD PARTUUID degil ($EXPECTED_ROOT)"
  ok "SSD cmdline gercek disk PARTUUID ile eslesiyor: $EXPECTED_ROOT"
elif [[ "$SKIP_MBR" == "yes" ]]; then
  log "WARN: MBR PARTUUID okunamadi (sudo yok) — cmdline eslesmesi yeterli sayildi"
else
  die "SSD MBR PARTUUID okunamadi"
fi

# Quirks / rootdelay (SD zorunlu — kernel SD'den)
SD_CMD="$(tr -d '\n' < "$BOOT_SD/cmdline.txt")"
echo "$SD_CMD" | grep -q 'usb-storage.quirks=' || die "SD cmdline quirks yok"
echo "$SD_CMD" | grep -qE 'rootdelay=[0-9]+' || die "SD cmdline rootdelay yok"
ok "SD quirks + rootdelay"

echo "$SD_CMD" | grep -qE '(^| )resize( |$)' || die "SD cmdline resize yok — partition genislemez"

# SD boot = firmware kaynagi; cloud-init dosyalari SD'de olmali
[[ -f "$BOOT_SD/ssh" ]] || die "SD bootfs ssh dosyasi yok (cloud-init SD'den okunur)"
[[ -f "$BOOT_SD/user-data" ]] || die "SD bootfs user-data yok"
ok "SD cloud-init (ssh + user-data)"

for f in user-data network-config userconf ssh; do
  cmp -s "$BOOT_SD/$f" "$BOOT_SSD/$f" || die "SD/SSD bootfs cloud-init farkli: $f"
done
ok "SD/SSD cloud-init ayni"

SSD_CMD="$(tr -d '\n' < "$BOOT_SSD/cmdline.txt")"
echo "$SSD_CMD" | grep -q 'usb-storage.quirks=' || log "WARN: SSD cmdline quirks yok"

# cloud-init kullanici
if [[ -f "$BOOT_SSD/user-data" ]]; then
  grep -q 'name: pi\|name: '"${PI_USER:-pi}" "$BOOT_SSD/user-data" 2>/dev/null \
    && ok "SSD user-data kullanici tanimli" \
    || log "WARN: SSD user-data kullanici satiri belirsiz"
fi
[[ -f "$BOOT_SSD/ssh" ]] && ok "SSD ssh enable dosyasi" || log "WARN: SSD ssh dosyasi yok"

log "Tum kontroller gecti"
