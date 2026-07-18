#!/usr/bin/env bash
# SSD boot partition'i forum/dokuman kanitli ayarlarla sertlestir (Mac)
# EEPROM ayarlari Pi'de SD ile yapilir — bu script sadece SSD FAT bootfs'e yazar.
set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "HATA: $*"; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "Sadece macOS"

find_pi_ssd() {
  local disk info size
  while read -r disk; do
    [[ -z "$disk" ]] && continue
    info=$(diskutil info "$disk" 2>/dev/null) || continue
    echo "$info" | grep -q "Internal" && continue
    size=$(echo "$info" | awk -F': *' '/Disk Size/ {print $2}' | head -1)
    echo "$size" | grep -qE "T|1000" && continue
    diskutil list "$disk" 2>/dev/null | grep -qE "bootfs|Linux" && { echo "$disk"; return 0; }
  done < <(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+ \(external/ {print $1}' | tr -d ':')
  return 1
}

detect_quirk() {
  local vid pid
  vid=$(ioreg -l 2>/dev/null | grep -A40 'YzWy  Disk Device' | grep '"idVendor"' | head -1 | sed 's/.*= //' | tr -d ' ')
  pid=$(ioreg -l 2>/dev/null | grep -A40 'YzWy  Disk Device' | grep '"idProduct"' | head -1 | sed 's/.*= //' | tr -d ' ')
  if [[ -n "$vid" && -n "$pid" && "$vid" =~ ^[0-9]+$ ]]; then
    printf "%04x:%04x:u" "$vid" "$pid"
    return 0
  fi
  echo "152d:0583:u"
}

DISK=$(find_pi_ssd) || die "Pi SSD bulunamadi"
QUIRK=$(detect_quirk)
diskutil mount "${DISK}s1" >/dev/null 2>&1 || true
[[ -d /Volumes/bootfs ]] || die "bootfs mount edilemedi"
BOOT="/Volumes/bootfs"

log "=== SSD Boot Harden ==="
log "Disk: $DISK | Quirk: $QUIRK"

# --- 1. Kritik dosyalar ---
for f in kernel8.img start4.elf bcm2711-rpi-4-b.dtb cmdline.txt config.txt; do
  [[ -f "$BOOT/$f" ]] || die "Eksik: $f"
done
log "1/5 Boot dosyalari OK"

# --- 2. cmdline.txt (kernel asaması — quirks burada) ---
# NOT: quirks rainbow/bootloader asamasini DUZELTMEZ; kernel acildiktan sonra UAS icin sart.
python3 - "$BOOT/cmdline.txt" "$QUIRK" <<'PY'
import sys
from pathlib import Path
path, quirk = Path(sys.argv[1]), sys.argv[2]
parts = path.read_text().replace("\n", "").split()
keep = [p for p in parts if not p.startswith("usb-storage.quirks=")
        and not p.startswith("rootdelay=")
        and p not in ("quiet", "splash")]
# rootwait zaten olmali
if "rootwait" not in keep:
    keep.append("rootwait")
out = [f"usb-storage.quirks={quirk}", "rootdelay=25"] + keep
path.write_text(" ".join(out) + "\n")
print(path.read_text().strip())
PY
log "2/5 cmdline.txt guncellendi (quirks + rootdelay=25, quiet/splash yok)"

# --- 3. config.txt ---
python3 - "$BOOT/config.txt" <<'PY'
from pathlib import Path
p = Path(__import__("sys").argv[1])
text = p.read_text()
settings = {
    "boot_delay": "5",
    "usb_max_current_enable": "1",
    "hdmi_force_hotplug": "1",
    "initial_turbo": "0",
}
lines = text.splitlines()
# remove existing keys in [all] or global
keys = set(settings)
out = []
for line in lines:
    key = line.split("=", 1)[0].strip() if "=" in line and not line.strip().startswith("#") else None
    if key in keys:
        continue
    out.append(line)
# ensure [all] section
if not any(l.strip() == "[all]" for l in out):
    out.append("")
    out.append("[all]")
# append settings after last [all]
idx = max(i for i, l in enumerate(out) if l.strip() == "[all]")
insert_at = idx + 1
while insert_at < len(out) and not out[insert_at].strip().startswith("["):
    insert_at += 1
block = [f"{k}={v}" for k, v in settings.items()]
out = out[:insert_at] + block + out[insert_at:]
p.write_text("\n".join(out) + "\n")
print("config settings:", settings)
PY
log "3/5 config.txt: boot_delay, hdmi, usb_max_current"

# --- 4. SSH + legacy userconf koru ---
touch "$BOOT/ssh"
[[ -f "$BOOT/user-data" ]] || die "user-data yok (cloud-init)"
grep -q "^enable_ssh: true" "$BOOT/user-data" || die "enable_ssh yok"
grep -q "name: batu" "$BOOT/user-data" || log "UYARI: user batu yok"
log "4/5 SSH / cloud-init OK"

# --- 5. Rapor ---
log "5/5 Dogrulama"
log "cmdline: $(cat "$BOOT/cmdline.txt")"
log "---"
grep -E '^(boot_delay|usb_max|hdmi_|initial_turbo)=' "$BOOT/config.txt" | while read -r l; do log "config: $l"; done
sync

cat <<EOF

=== MAC TARAFI TAMAM ===
SSD bootfs hazir. Rainbow/bootloader icin Pi EEPROM: scripts/pi/fix-eeprom-usb-ssd.sh

A mimarisi (SD boot + SSD root) icin migrate kullan:
  ./scripts/mac/migrate-sd-boot-ssd-root.sh

B mimarisi (tam USB boot, SD cikar) test:
  1. Pi SD ile ac → CONFIRM_EEPROM_FIX=yes ARCH=B fix-eeprom-usb-ssd.sh
  2. SD cikar, SSD USB 2.0 → ac

EOF
