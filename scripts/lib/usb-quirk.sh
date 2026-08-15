#!/usr/bin/env bash
# USB storage + usbcore quirks (JMicron JMS583 vb.) — Mac migrate/flash/cmdline
set -euo pipefail

# usb-storage :u = IGNORE_UAS (bulk-only). usbcore :k = USB_QUIRK_NO_LPM.
detect_usb_quirk() {
  local override="${PI_USB_QUIRK:-}"
  if [[ -n "$override" ]]; then
    echo "$override"
    return 0
  fi

  local vid pid
  for pattern in 'YongzhenWeiye' 'YzWy  Disk Device' 'USB Storage' 'JMicron' '152d'; do
    vid=$(ioreg -l 2>/dev/null | grep -A40 "$pattern" | grep '"idVendor"' | head -1 | sed 's/.*= //' | tr -d ' ' || true)
    pid=$(ioreg -l 2>/dev/null | grep -A40 "$pattern" | grep '"idProduct"' | head -1 | sed 's/.*= //' | tr -d ' ' || true)
    [[ -n "$vid" && -n "$pid" && "$vid" =~ ^[0-9]+$ ]] && break
  done

  if [[ -n "$vid" && -n "$pid" && "$vid" =~ ^[0-9]+$ ]]; then
    printf '%04x:%04x:u' "$vid" "$pid"
  else
    echo "152d:0583:u"
  fi
}

# 152d:0583:u veya 152d:0583 → usb-storage :u (UAS ignore)
normalize_storage_quirk() {
  local s="${1:-152d:0583:u}"
  if [[ "$s" =~ ^([0-9a-fA-F]{4}:[0-9a-fA-F]{4})(:u)?$ ]]; then
    echo "${BASH_REMATCH[1]}:u"
  else
    echo "152d:0583:u"
  fi
}

# usbcore :k = USB_QUIRK_NO_LPM. ${var%:*} 152d:0583'i 152d yapar — regex sart.
usbcore_quirk_from_storage() {
  local storage="${1:-152d:0583:u}"
  if [[ "$storage" =~ ^([0-9a-fA-F]{4}:[0-9a-fA-F]{4}) ]]; then
    echo "${BASH_REMATCH[1]}:k"
  else
    echo "152d:0583:k"
  fi
}

# cmdline: UAS off + NO_LPM + autosuspend=-1 + rootdelay; duplicate rootwait/rootfstype sil
apply_jmicron_cmdline_file() {
  local file="$1"
  local storage_q="${2:-}"
  [[ -f "$file" ]] || return 1
  if [[ -z "$storage_q" ]]; then
    storage_q="$(detect_usb_quirk)"
  fi
  storage_q="$(normalize_storage_quirk "$storage_q")"
  python3 - "$file" "$storage_q" "$(usbcore_quirk_from_storage "$storage_q")" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
storage_q, usbcore_q = sys.argv[2], sys.argv[3]
parts = path.read_text().replace("\n", " ").split()
drop_pfx = (
    "usb-storage.quirks=",
    "usbcore.quirks=",
    "usbcore.autosuspend=",
    "rootdelay=",
)
seen = set()
keep = []
for p in parts:
    if p.startswith(drop_pfx) or p in ("quiet", "splash"):
        continue
    if p == "rootwait" and p in seen:
        continue
    if p.startswith("rootfstype=") and any(x.startswith("rootfstype=") for x in keep):
        continue
    seen.add(p)
    keep.append(p)
if "rootwait" not in keep:
    keep.append("rootwait")
out = [
    f"usb-storage.quirks={storage_q}",
    f"usbcore.quirks={usbcore_q}",
    "usbcore.autosuspend=-1",
    "rootdelay=25",
] + keep
text = " ".join(out) + "\n"
tmp = path.with_name(path.name + ".tmp-jmicron")
try:
    tmp.write_text(text)
    tmp.replace(path)
finally:
    if tmp.exists() and tmp.resolve() != path.resolve():
        tmp.unlink(missing_ok=True)
print(path.read_text().strip())
PY
}
