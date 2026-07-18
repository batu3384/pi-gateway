#!/usr/bin/env bash
# USB storage quirk (JMicron vb.) — Mac migrate/flash icin
set -euo pipefail

detect_usb_quirk() {
  local override="${PI_USB_QUIRK:-}"
  if [[ -n "$override" ]]; then
    echo "$override"
    return 0
  fi

  local vid pid
  # Imager / migrate sirasinda SSD diskinin VID:PID
  for pattern in 'YzWy  Disk Device' 'USB Storage' 'JMicron' '152d'; do
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
