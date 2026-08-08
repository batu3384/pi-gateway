#!/usr/bin/env bash
# SSD canlilik: block var mi, mount saglikli mi, soft-reset, remount
# stack-health.sh tarafindan source edilir; stack-health'e bagimli DEGIL.
# shellcheck shell=bash

SSD_MOUNT="${SSD_MOUNT:-/mnt/ssd}"
SSD_LABEL="${SSD_LABEL:-pi-data}"
# .disk-probe dizindir (setup-ssd-data); yazma probe ayri dosya
SSD_PROBE_FILE="${SSD_PROBE_FILE:-${SSD_MOUNT}/.pi-gateway-io-probe}"
SSD_PROBE_TIMEOUT_SEC="${SSD_PROBE_TIMEOUT_SEC:-3}"
SSD_USB_VID="${SSD_USB_VID:-152d}"
SSD_USB_PID="${SSD_USB_PID:-0583}"
SSD_USB_RESET_MAX="${SSD_USB_RESET_MAX:-3}"
SSD_USB_RESET_WINDOW_SEC="${SSD_USB_RESET_WINDOW_SEC:-900}"
SSD_USB_RESET_STATE_FILE="${SSD_USB_RESET_STATE_FILE:-/var/lib/pi-gateway/ssd-usb-reset-state}"
# ponytail: total bus dropout soft-reset ile kurtulamayabilir — SSD_USB_RESET_REBOOT=true upgrade
SSD_USB_RESET_REBOOT="${SSD_USB_RESET_REBOOT:-false}"
# JMicron authorized 0→1 bazi kutularda enumerate kaybettirir — varsayilan kapali
SSD_USB_AUTHORIZED_RESET="${SSD_USB_AUTHORIZED_RESET:-false}"

_ssd_alive_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

_ssd_probe_write() {
  local probe="$1"
  [[ -n "$probe" && ! -d "$probe" ]] || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout "$SSD_PROBE_TIMEOUT_SEC" bash -c "echo \"ok \$(date +%s)\" >'${probe}'" 2>/dev/null
  else
    echo "ok $(date +%s)" >"$probe" 2>/dev/null
  fi
}

ssd_block_present() {
  local by_label part
  by_label="$(blkid -L "$SSD_LABEL" 2>/dev/null || true)"
  if [[ -n "$by_label" && -b "$by_label" ]]; then
    return 0
  fi
  if [[ -e "/dev/disk/by-label/${SSD_LABEL}" ]]; then
    return 0
  fi
  part="$(awk '$2=="/mnt/ssd" && $1 !~ /^#/ {print $1; exit}' /etc/fstab 2>/dev/null || true)"
  if [[ -n "$part" ]]; then
    if [[ "$part" == PARTUUID=* || "$part" == UUID=* ]]; then
      blkid "$part" -o device >/dev/null 2>&1 && return 0
    elif [[ -b "$part" ]]; then
      return 0
    fi
  fi
  return 1
}

# mountpoint + kisa yazma probe — timeout = stale/hung mount
ssd_mount_healthy() {
  mountpoint -q "$SSD_MOUNT" 2>/dev/null || return 1
  local probe
  # Once user-writable data agaci (sudo zorunlu olmasin)
  for probe in \
    "${SSD_MOUNT}/pi-gateway-data/.pi-gateway-io-probe" \
    "${SSD_PROBE_FILE}"; do
    [[ -d "$probe" ]] && continue
    if _ssd_probe_write "$probe"; then
      return 0
    fi
  done
  # Root fallback (mount root root-owned)
  for probe in "${SSD_PROBE_FILE}" "${SSD_MOUNT}/.pi-gateway-io-probe"; do
    [[ -d "$probe" ]] && continue
    if [[ "$(id -u)" -eq 0 ]]; then
      _ssd_probe_write "$probe" && return 0
    else
      if command -v timeout >/dev/null 2>&1; then
        timeout "$SSD_PROBE_TIMEOUT_SEC" sudo bash -c "echo \"ok \$(date +%s)\" >'${probe}'" 2>/dev/null && return 0
      else
        sudo bash -c "echo ok \$(date +%s) >'${probe}'" 2>/dev/null && return 0
      fi
    fi
  done
  return 1
}

ssd_find_usb_sysfs() {
  local d vid pid expect_vid expect_pid
  expect_vid="$(printf '%s' "$SSD_USB_VID" | tr '[:upper:]' '[:lower:]')"
  expect_pid="$(printf '%s' "$SSD_USB_PID" | tr '[:upper:]' '[:lower:]')"
  for d in /sys/bus/usb/devices/*; do
    [[ -f "${d}/idVendor" && -f "${d}/idProduct" ]] || continue
    vid="$(tr '[:upper:]' '[:lower:]' <"${d}/idVendor" 2>/dev/null || true)"
    pid="$(tr '[:upper:]' '[:lower:]' <"${d}/idProduct" 2>/dev/null || true)"
    [[ "$vid" == "$expect_vid" && "$pid" == "$expect_pid" ]] || continue
    echo "$d"
    return 0
  done
  return 1
}

ssd_usb_disable_autosuspend() {
  local sys
  sys="$(ssd_find_usb_sysfs 2>/dev/null || true)"
  [[ -n "$sys" ]] || return 0
  if [[ -f "${sys}/power/control" ]]; then
    _ssd_alive_root bash -c "echo on >'${sys}/power/control'" 2>/dev/null || true
  fi
  if [[ -f "${sys}/power/autosuspend" ]]; then
    _ssd_alive_root bash -c "echo -1 >'${sys}/power/autosuspend'" 2>/dev/null || true
  fi
  if [[ -f "${sys}/power/autosuspend_delay_ms" ]]; then
    _ssd_alive_root bash -c "echo -1 >'${sys}/power/autosuspend_delay_ms'" 2>/dev/null || true
  fi
}

ssd_usb_reset_rate_limited() {
  local now count ts
  now="$(date +%s)"
  if [[ -f "$SSD_USB_RESET_STATE_FILE" ]]; then
    read -r ts count <"$SSD_USB_RESET_STATE_FILE" || true
    ts="${ts:-0}"
    count="${count:-0}"
    if (( now - ts < SSD_USB_RESET_WINDOW_SEC )) && (( count >= SSD_USB_RESET_MAX )); then
      return 0
    fi
  fi
  return 1
}

ssd_usb_reset_record() {
  local now count ts
  now="$(date +%s)"
  _ssd_alive_root mkdir -p "$(dirname "$SSD_USB_RESET_STATE_FILE")" 2>/dev/null || true
  if [[ -f "$SSD_USB_RESET_STATE_FILE" ]]; then
    read -r ts count <"$SSD_USB_RESET_STATE_FILE" || true
    ts="${ts:-0}"
    count="${count:-0}"
    if (( now - ts >= SSD_USB_RESET_WINDOW_SEC )); then
      ts="$now"
      count=0
    fi
  else
    ts="$now"
    count=0
  fi
  count=$((count + 1))
  if [[ "$(id -u)" -eq 0 ]]; then
    printf '%s %s\n' "$ts" "$count" >"$SSD_USB_RESET_STATE_FILE"
  else
    printf '%s %s\n' "$ts" "$count" | sudo tee "$SSD_USB_RESET_STATE_FILE" >/dev/null
  fi
}

# Soft-reset: autosuspend off + remount; authorized cycle sadece opt-in (rate-limit)
ssd_usb_soft_reset() {
  ssd_usb_disable_autosuspend

  if [[ "$SSD_USB_AUTHORIZED_RESET" == "true" ]]; then
    if ssd_usb_reset_rate_limited; then
      echo "[ssd-alive] USB authorized rate-limit (${SSD_USB_RESET_MAX}/${SSD_USB_RESET_WINDOW_SEC}s)" >&2
      if [[ "$SSD_USB_RESET_REBOOT" == "true" ]]; then
        echo "[ssd-alive] SSD_USB_RESET_REBOOT=true — reboot" >&2
        _ssd_alive_root systemctl reboot || true
      fi
      return 1
    fi
    local sys
    sys="$(ssd_find_usb_sysfs 2>/dev/null || true)"
    if [[ -n "$sys" && -f "${sys}/authorized" ]]; then
      ssd_usb_reset_record
      echo "[ssd-alive] USB authorized cycle: $sys" >&2
      _ssd_alive_root bash -c "echo 0 >'${sys}/authorized'" 2>/dev/null || true
      sleep 2
      _ssd_alive_root bash -c "echo 1 >'${sys}/authorized'" 2>/dev/null || true
      command -v udevadm >/dev/null 2>&1 && _ssd_alive_root udevadm settle --timeout=10 2>/dev/null || sleep 3
    else
      echo "[ssd-alive] USB cihaz yok — authorized atlandi" >&2
    fi
  fi

  if mountpoint -q "$SSD_MOUNT" 2>/dev/null && ! ssd_mount_healthy; then
    _ssd_alive_root umount -l "$SSD_MOUNT" 2>/dev/null || true
  fi
  if ssd_block_present; then
    local disk
    disk="$(blkid -L "$SSD_LABEL" 2>/dev/null || true)"
    if [[ -n "$disk" ]]; then
      _ssd_alive_root partprobe "$(echo "$disk" | sed -E 's/p?[0-9]+$//')" 2>/dev/null || true
    fi
  fi
  ssd_try_remount || true
  ssd_mount_healthy
}

ssd_try_remount() {
  if ssd_mount_healthy; then
    return 0
  fi
  if mountpoint -q "$SSD_MOUNT" 2>/dev/null && ! ssd_mount_healthy; then
    _ssd_alive_root umount -l "$SSD_MOUNT" 2>/dev/null || true
  fi
  ssd_block_present || return 1
  _ssd_alive_root systemctl start mnt-ssd.mount 2>/dev/null \
    || _ssd_alive_root mount "$SSD_MOUNT" 2>/dev/null \
    || return 1
  ssd_mount_healthy
}

ssd_quirk_present() {
  local f
  for f in /boot/firmware/cmdline.txt /media/*/bootfs/cmdline.txt /boot/cmdline.txt; do
    [[ -r "$f" ]] || continue
    if grep -q "usb-storage.quirks=${SSD_USB_VID}:${SSD_USB_PID}:u" "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

ssd_recent_io_errors() {
  journalctl -k -b --no-pager --since "15 min ago" 2>/dev/null \
    | grep -qiE 'I/O error.*sd[a-z]|Buffer I/O error on dev sd|usb .*disconnect|reset SuperSpeed USB|reset high-speed USB'
}

# vcgencmd get_throttled — bit0 now, bit16 occurred
ssd_under_voltage() {
  command -v vcgencmd >/dev/null 2>&1 || return 1
  local raw hex val
  raw="$(vcgencmd get_throttled 2>/dev/null || true)"
  hex="${raw#*0x}"
  [[ "$hex" =~ ^[0-9a-fA-F]+$ ]] || return 1
  val=$((16#$hex))
  (( (val & 0x1) != 0 || (val & 0x10000) != 0 ))
}
