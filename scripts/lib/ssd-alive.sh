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
# lsusb bos + block yok: host port disable (tak-cikar yerine yazilim)
SSD_USB_PORT_DISABLE_CYCLE="${SSD_USB_PORT_DISABLE_CYCLE:-true}"
# 0 = hatirlanan + USB3 once; >0 = once bu port numarasi
SSD_USB_HOST_PORT="${SSD_USB_HOST_PORT:-0}"
SSD_USB_PORT_STATE_FILE="${SSD_USB_PORT_STATE_FILE:-/var/lib/pi-gateway/ssd-usb-port}"
SSD_USB_PORT_FAILS_FILE="${SSD_USB_PORT_FAILS_FILE:-/var/lib/pi-gateway/ssd-usb-port-fails}"
SSD_USB_PORT_CURSOR_FILE="${SSD_USB_PORT_CURSOR_FILE:-/var/lib/pi-gateway/ssd-usb-port-cursor}"
# Bus dropout + bu kadar basarisiz tam tarama → hatirlanan port silinir
SSD_USB_PORT_FORGET_FAILS="${SSD_USB_PORT_FORGET_FAILS:-2}"
SSD_USB_PORT_ROTATE="${SSD_USB_PORT_ROTATE:-true}"
SSD_USB_PORT_OFF_SEC="${SSD_USB_PORT_OFF_SEC:-5}"
SSD_USB_PORT_ON_SEC="${SSD_USB_PORT_ON_SEC:-10}"
# Hatirlanan porttan sonra kac ekstra USB3 port (Pi4: platform usb2-port1..4)
SSD_USB_PORT_SCAN_MAX="${SSD_USB_PORT_SCAN_MAX:-8}"
SSD_USB_RESET_LOCK_WAIT_SEC="${SSD_USB_RESET_LOCK_WAIT_SEC:-45}"
# USB hala enumerate ama I/O olu: port cycle
SSD_USB_CYCLE_ON_HANG="${SSD_USB_CYCLE_ON_HANG:-true}"
# Port power'dan once usb-storage unbind/bind
SSD_USB_STORAGE_REBIND="${SSD_USB_STORAGE_REBIND:-true}"
# Bir soft_reset icinde rate-limit tek say
SSD_USB_RESET_COUNTED=0
# Son care: xhci PCI unbind/rebind (rate-limit; varsayilan KAPALI — tum USB3 collateral)
SSD_USB_XHCI_REBIND="${SSD_USB_XHCI_REBIND:-false}"
SSD_USB_XHCI_PCI="${SSD_USB_XHCI_PCI:-0000:01:00.0}"
SSD_USB_XHCI_UNBIND_SEC="${SSD_USB_XHCI_UNBIND_SEC:-5}"
SSD_USB_XHCI_BIND_SEC="${SSD_USB_XHCI_BIND_SEC:-12}"
SSD_USB_REBOOT_STAMP_FILE="${SSD_USB_REBOOT_STAMP_FILE:-/var/lib/pi-gateway/ssd-usb-reboot-stamp}"
SSD_USB_RESET_LOCK_DIR="${SSD_USB_RESET_LOCK_DIR:-/run/pi-gateway/ssd-usb-reset.lock}"

_ssd_alive_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# PCI BDF: 0000:01:00.0 — bash -c injection engeli
ssd_pci_id_ok() {
  [[ "$1" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$ ]]
}

ssd_sysfs_write() {
  local path="$1" value="$2"
  [[ "$path" == /sys/* ]] || return 1
  [[ -e "$path" ]] || return 1
  printf '%s\n' "$value" | _ssd_alive_root tee "$path" >/dev/null
}

_ssd_probe_path_ok() {
  local probe="$1"
  [[ -n "$probe" && "$probe" == /* && ! -d "$probe" ]] || return 1
  [[ "$probe" != *$'\n'* && "$probe" != *$'\r'* ]] || return 1
}

_ssd_probe_write() {
  local probe="$1"
  _ssd_probe_path_ok "$probe" || return 1
  # fsync: page-cache write JMS583 hung mount'ta false-green olur
  if command -v python3 >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      timeout "$SSD_PROBE_TIMEOUT_SEC" python3 -c '
import os, sys, time
p = sys.argv[1]
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
try:
    os.write(fd, ("ok %d\n" % int(time.time())).encode())
    os.fsync(fd)
finally:
    os.close(fd)
' "$probe" 2>/dev/null
    else
      python3 -c '
import os, sys, time
p = sys.argv[1]
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
try:
    os.write(fd, ("ok %d\n" % int(time.time())).encode())
    os.fsync(fd)
finally:
    os.close(fd)
' "$probe" 2>/dev/null
    fi
  else
    printf 'ok %s\n' "$(date +%s)" >"$probe" 2>/dev/null
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
  part="$(awk -v m="$SSD_MOUNT" '$2==m && $1 !~ /^#/ {print $1; exit}' /etc/fstab 2>/dev/null || true)"
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
    _ssd_probe_path_ok "$probe" || continue
    if [[ "$(id -u)" -eq 0 ]]; then
      _ssd_probe_write "$probe" && return 0
    else
      if command -v python3 >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
        timeout "$SSD_PROBE_TIMEOUT_SEC" sudo python3 -c '
import os, sys, time
p = sys.argv[1]
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
try:
    os.write(fd, ("ok %d\n" % int(time.time())).encode())
    os.fsync(fd)
finally:
    os.close(fd)
' "$probe" 2>/dev/null && return 0
      else
        printf 'ok %s\n' "$(date +%s)" | sudo tee "$probe" >/dev/null 2>/dev/null && return 0
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

ssd_usb_port_label() {
  basename "${1:-unknown}"
}

_ssd_usb_port_canon() {
  readlink -f "$1" 2>/dev/null || echo "$1"
}

ssd_usb_port_fail_get() {
  local port="$1" line key cnt
  port="$(_ssd_usb_port_canon "$port")"
  [[ -f "$SSD_USB_PORT_FAILS_FILE" ]] || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="${line%% *}"
    cnt="${line##* }"
    key="$(_ssd_usb_port_canon "$key")"
    if [[ "$key" == "$port" && "$cnt" =~ ^[0-9]+$ ]]; then
      echo "$cnt"
      return 0
    fi
  done <"$SSD_USB_PORT_FAILS_FILE"
  return 1
}

ssd_usb_port_fail_record() {
  local port="$1" fails=0 line key cnt updated=0 tmp
  port="$(_ssd_usb_port_canon "$port")"
  ssd_usb_port_path_ok "$port" || return 1
  fails="$(ssd_usb_port_fail_get "$port" 2>/dev/null || echo 0)"
  fails=$((fails + 1))
  tmp="$(mktemp)"
  _ssd_alive_root mkdir -p "$(dirname "$SSD_USB_PORT_FAILS_FILE")" 2>/dev/null || true
  if [[ -f "$SSD_USB_PORT_FAILS_FILE" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      key="${line%% *}"
      cnt="${line##* }"
      key="$(_ssd_usb_port_canon "$key")"
      if [[ "$key" == "$port" ]]; then
        printf '%s %s\n' "$port" "$fails" >>"$tmp"
        updated=1
      else
        printf '%s\n' "$line" >>"$tmp"
      fi
    done <"$SSD_USB_PORT_FAILS_FILE"
  fi
  [[ "$updated" -eq 1 ]] || printf '%s %s\n' "$port" "$fails" >>"$tmp"
  if [[ "$(id -u)" -eq 0 ]]; then
    install -m 644 "$tmp" "$SSD_USB_PORT_FAILS_FILE"
  else
    _ssd_alive_root install -m 644 "$tmp" "$SSD_USB_PORT_FAILS_FILE"
  fi
  rm -f "$tmp"
}

ssd_usb_port_fail_clear() {
  local port="$1" line key tmp updated=0
  port="$(_ssd_usb_port_canon "$port")"
  [[ -f "$SSD_USB_PORT_FAILS_FILE" ]] || return 0
  tmp="$(mktemp)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="${line%% *}"
    key="$(_ssd_usb_port_canon "$key")"
    if [[ "$key" == "$port" ]]; then
      updated=1
      continue
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$SSD_USB_PORT_FAILS_FILE"
  if [[ "$updated" -eq 1 ]]; then
    if [[ -s "$tmp" ]]; then
      if [[ "$(id -u)" -eq 0 ]]; then
        install -m 644 "$tmp" "$SSD_USB_PORT_FAILS_FILE"
      else
        _ssd_alive_root install -m 644 "$tmp" "$SSD_USB_PORT_FAILS_FILE"
      fi
    else
      _ssd_alive_root rm -f "$SSD_USB_PORT_FAILS_FILE" 2>/dev/null || true
    fi
  fi
  rm -f "$tmp"
}

ssd_usb_port_forget() {
  _ssd_alive_root rm -f "$SSD_USB_PORT_STATE_FILE" 2>/dev/null || true
  echo "[ssd-alive] hatirlanan USB port silindi (basarisiz tarama)" >&2
}

ssd_usb_remember_port() {
  local sys port_sys prev=""
  sys="$(ssd_find_usb_sysfs 2>/dev/null || true)"
  [[ -n "$sys" && -L "${sys}/port" ]] || return 1
  port_sys="$(_ssd_usb_port_canon "$(readlink -f "${sys}/port" 2>/dev/null || true)")"
  ssd_usb_port_path_ok "$port_sys" || return 1
  if [[ -f "$SSD_USB_PORT_STATE_FILE" ]]; then
    prev="$(tr -d '[:space:]' <"$SSD_USB_PORT_STATE_FILE" 2>/dev/null || true)"
    prev="$(_ssd_usb_port_canon "$prev")"
  fi
  _ssd_alive_root mkdir -p "$(dirname "$SSD_USB_PORT_STATE_FILE")" 2>/dev/null || true
  if [[ "$(id -u)" -eq 0 ]]; then
    printf '%s\n' "$port_sys" >"$SSD_USB_PORT_STATE_FILE"
  else
    printf '%s\n' "$port_sys" | sudo tee "$SSD_USB_PORT_STATE_FILE" >/dev/null
  fi
  ssd_usb_port_fail_clear "$port_sys" || true
  if [[ "$prev" != "$port_sys" ]]; then
    echo "[ssd-alive] SSD port ogrenildi: $(ssd_usb_port_label "$port_sys")" >&2
  fi
}

# udev/hotplug: enumerate varsa port dosyasini guncelle
ssd_usb_learn_live_port() {
  ssd_usb_remember_port
}

ssd_usb_disable_lpm() {
  local sys f
  sys="$(ssd_find_usb_sysfs 2>/dev/null || true)"
  [[ -n "$sys" ]] || return 0
  for f in \
    "${sys}/power/usb3_hardware_lpm_u1" \
    "${sys}/power/usb3_hardware_lpm_u2" \
    "${sys}/power/usb3_lpm_permit"; do
    [[ -f "$f" ]] || continue
    ssd_sysfs_write "$f" 0 || ssd_sysfs_write "$f" disable || true
  done
}

ssd_usb_disable_autosuspend() {
  local sys
  if [[ -f /sys/module/usbcore/parameters/autosuspend ]]; then
    ssd_sysfs_write /sys/module/usbcore/parameters/autosuspend -1 || true
  fi
  sys="$(ssd_find_usb_sysfs 2>/dev/null || true)"
  [[ -n "$sys" ]] || return 0
  if [[ -f "${sys}/power/control" ]]; then
    ssd_sysfs_write "${sys}/power/control" on || true
  fi
  if [[ -f "${sys}/power/autosuspend" ]]; then
    ssd_sysfs_write "${sys}/power/autosuspend" -1 || true
  fi
  if [[ -f "${sys}/power/autosuspend_delay_ms" ]]; then
    ssd_sysfs_write "${sys}/power/autosuspend_delay_ms" -1 || true
  fi
  ssd_usb_disable_lpm
  ssd_usb_remember_port || true
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

ssd_usb_reset_record_once() {
  [[ "${SSD_USB_RESET_COUNTED:-0}" == "1" ]] && return 0
  ssd_usb_reset_record
  SSD_USB_RESET_COUNTED=1
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

ssd_usb_bus_dropout() {
  ssd_find_usb_sysfs >/dev/null 2>&1 && return 1
  ssd_block_present && return 1
  return 0
}

ssd_usb_port_path_ok() {
  local p="$1"
  [[ "$p" == /sys/* ]] || return 1
  # usb2-portN (xhci) veya 1-1-portN (Pi4 USB2 VIA hub)
  [[ "$p" =~ /usb[0-9]+-port[0-9]+$ || "$p" =~ /[0-9]+-[0-9.]+-port[0-9]+$ ]] || return 1
  [[ -f "${p}/disable" ]] || return 1
}

ssd_usb_iface_ok() {
  [[ "$1" =~ ^[0-9]+-[0-9.]+(:[0-9]+\.[0-9]+)$ ]]
}

ssd_usb_port_sysfs() {
  local port="${SSD_USB_HOST_PORT:-0}"
  local p
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port > 0 )) || return 1
  for p in \
    "/sys/bus/usb/devices/usb2-port${port}" \
    "/sys/bus/usb/devices/usb1-port${port}" \
    "/sys/devices/platform/scb/fd500000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0/usb2/2-0:1.0/usb2-port${port}"; do
    ssd_usb_port_path_ok "$p" && { echo "$p"; return 0; }
  done
  return 1
}

# Pi4: /sys/bus/usb/devices/usb2-portN yok; gercek path
# USB3: .../usb2/2-0:1.0/usb2-portN  USB2: .../1-1:1.0/1-1-portN
# usb1-port1 = VIA hub kok — tarama disi (tum USB2 collateral)
ssd_usb_discover_xhci_ports() {
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    ssd_usb_port_path_ok "$p" && printf '%s\n' "$p"
  done < <(find /sys/devices/platform/scb /sys/bus/usb/devices \
    \( -name 'usb2-port[1-4]' -o -name '1-1-port[1-4]' \) 2>/dev/null | sort)
}

_ssd_port_emit() {
  local x r
  x="$1"
  ssd_usb_port_path_ok "$x" || return 0
  r="$(_ssd_usb_port_canon "$x")"
  [[ "${_SSD_PORT_SEEN:-}" == *"|${r}|"* ]] && return 0
  _SSD_PORT_SEEN="${_SSD_PORT_SEEN:-|}${r}|"
  printf '%s\n' "$r"
}

_ssd_usb_port_collect_raw() {
  local p remembered="" q
  _SSD_PORT_SEEN="|"
  if [[ -f "$SSD_USB_PORT_STATE_FILE" ]]; then
    remembered="$(tr -d '[:space:]' <"$SSD_USB_PORT_STATE_FILE" 2>/dev/null || true)"
    _ssd_port_emit "$remembered"
  fi
  p="$(ssd_usb_port_sysfs 2>/dev/null || true)"
  [[ -n "$p" ]] && _ssd_port_emit "$p"
  while IFS= read -r q; do
    [[ -n "$q" ]] && _ssd_port_emit "$q"
  done < <(ssd_usb_discover_xhci_ports)
}

# Dusuk fail → once; cursor ile her tick farkli porttan basla
ssd_usb_port_candidates() {
  local -a raw=() ordered=() out=()
  local remembered="" rfails=0 cursor=0 i n f line p

  if ssd_find_usb_sysfs >/dev/null 2>&1; then
    ssd_usb_learn_live_port || true
  elif ssd_usb_bus_dropout && [[ -f "$SSD_USB_PORT_STATE_FILE" ]]; then
    remembered="$(tr -d '[:space:]' <"$SSD_USB_PORT_STATE_FILE" 2>/dev/null || true)"
    rfails="$(ssd_usb_port_fail_get "$remembered" 2>/dev/null || echo 0)"
    if [[ "$rfails" =~ ^[0-9]+$ ]] \
      && (( rfails >= SSD_USB_PORT_FORGET_FAILS )); then
      ssd_usb_port_forget
    fi
  fi

  while IFS= read -r p; do
    [[ -n "$p" ]] && raw+=("$p")
  done < <(_ssd_usb_port_collect_raw)
  ((${#raw[@]} > 0)) || return 0

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ordered+=("${line#* }")
  done < <(
    for p in "${raw[@]}"; do
      f="$(ssd_usb_port_fail_get "$p" 2>/dev/null || echo 0)"
      [[ "$f" =~ ^[0-9]+$ ]] || f=0
      printf '%04d %s\n' "$f" "$p"
    done | sort -n | awk '{ $1=""; sub(/^ /,""); print }'
  )

  if [[ "${SSD_USB_PORT_ROTATE:-true}" == "true" ]] && ((${#ordered[@]} > 1)); then
    if [[ -f "$SSD_USB_PORT_CURSOR_FILE" ]]; then
      cursor="$(tr -d '[:space:]' <"$SSD_USB_PORT_CURSOR_FILE" 2>/dev/null || echo 0)"
      [[ "$cursor" =~ ^[0-9]+$ ]] || cursor=0
    fi
    cursor=$((cursor % ${#ordered[@]}))
    for ((i = 0; i < ${#ordered[@]}; i++)); do
      out+=("${ordered[$(( (cursor + i) % ${#ordered[@]} ))]}")
    done
    n=$(( (cursor + 1) % ${#ordered[@]} ))
    _ssd_alive_root mkdir -p "$(dirname "$SSD_USB_PORT_CURSOR_FILE")" 2>/dev/null || true
    if [[ "$(id -u)" -eq 0 ]]; then
      printf '%s\n' "$n" >"$SSD_USB_PORT_CURSOR_FILE"
    else
      printf '%s\n' "$n" | sudo tee "$SSD_USB_PORT_CURSOR_FILE" >/dev/null
    fi
    printf '%s\n' "${out[@]}"
    return 0
  fi

  printf '%s\n' "${ordered[@]}"
}

ssd_usb_port_cycle_one() {
  local port_sys="$1"
  ssd_usb_port_path_ok "$port_sys" || return 1
  echo "[ssd-alive] USB port disable cycle: $port_sys" >&2
  ssd_sysfs_write "${port_sys}/disable" 1 || return 1
  sleep "${SSD_USB_PORT_OFF_SEC:-5}"
  ssd_sysfs_write "${port_sys}/disable" 0 || true
  sleep "${SSD_USB_PORT_ON_SEC:-10}"
  command -v udevadm >/dev/null 2>&1 && _ssd_alive_root udevadm settle --timeout=15 2>/dev/null || sleep 3
  if ssd_find_usb_sysfs >/dev/null 2>&1 || ssd_block_present; then
    ssd_usb_learn_live_port || true
    return 0
  fi
  return 1
}

ssd_usb_port_disable_cycle() {
  [[ "${SSD_USB_PORT_DISABLE_CYCLE:-true}" == "true" ]] || return 1
  if ssd_usb_reset_rate_limited; then
    echo "[ssd-alive] port disable rate-limit (${SSD_USB_RESET_MAX}/${SSD_USB_RESET_WINDOW_SEC}s)" >&2
    return 1
  fi
  local port_sys tried=0 max_extra i
  max_extra="${SSD_USB_PORT_SCAN_MAX:-8}"
  [[ "$max_extra" =~ ^[0-9]+$ ]] || max_extra=8
  local -a ports=()
  while IFS= read -r port_sys; do
    [[ -n "$port_sys" ]] || continue
    ssd_usb_port_path_ok "$port_sys" || continue
    ports+=("$port_sys")
  done < <(ssd_usb_port_candidates)
  ((${#ports[@]} > 0)) || return 1
  echo "[ssd-alive] port tarama: ${#ports[@]} aday (ilk=$(ssd_usb_port_label "${ports[0]}"))" >&2
  if ssd_usb_port_cycle_one "${ports[0]}"; then
    ssd_usb_reset_record_once
    return 0
  fi
  ssd_usb_port_fail_record "${ports[0]}" || true
  for ((i = 1; i < ${#ports[@]} && tried < max_extra; i++)); do
    tried=$((tried + 1))
    if ssd_usb_port_cycle_one "${ports[$i]}"; then
      ssd_usb_reset_record_once
      return 0
    fi
    ssd_usb_port_fail_record "${ports[$i]}" || true
  done
  ssd_usb_reset_record_once
  return 1
}

# Cihaz var, SCSI katmani donmus: unbind/bind (port power'dan hafif)
ssd_usb_storage_rebind() {
  [[ "${SSD_USB_STORAGE_REBIND:-true}" == "true" ]] || return 1
  local sys iface name any=0
  sys="$(ssd_find_usb_sysfs 2>/dev/null || true)"
  [[ -n "$sys" && -d /sys/bus/usb/drivers/usb-storage ]] || return 1
  for iface in "$sys":*; do
    [[ -e "$iface" ]] || continue
    name="${iface##*/}"
    ssd_usb_iface_ok "$name" || continue
    [[ -e "/sys/bus/usb/drivers/usb-storage/$name" ]] || continue
    echo "[ssd-alive] usb-storage unbind/bind: $name" >&2
    ssd_sysfs_write /sys/bus/usb/drivers/usb-storage/unbind "$name" || true
    sleep 1
    ssd_sysfs_write /sys/bus/usb/drivers/usb-storage/bind "$name" || true
    any=1
  done
  (( any == 1 )) || return 1
  sleep 2
  command -v udevadm >/dev/null 2>&1 && _ssd_alive_root udevadm settle --timeout=10 2>/dev/null || true
  ssd_block_present
}

ssd_xhci_rebind() {
  [[ "${SSD_USB_XHCI_REBIND:-false}" == "true" ]] || return 1
  if ssd_usb_reset_rate_limited; then
    echo "[ssd-alive] xhci rebind rate-limit (${SSD_USB_RESET_MAX}/${SSD_USB_RESET_WINDOW_SEC}s)" >&2
    return 1
  fi
  local dev="${SSD_USB_XHCI_PCI:-0000:01:00.0}"
  ssd_pci_id_ok "$dev" || {
    echo "[ssd-alive] HATA: SSD_USB_XHCI_PCI gecersiz: $dev" >&2
    return 1
  }
  [[ -e "/sys/bus/pci/drivers/xhci_hcd/${dev}" ]] || return 1
  ssd_usb_reset_record_once
  echo "[ssd-alive] xhci rebind: $dev" >&2
  ssd_sysfs_write "/sys/bus/pci/drivers/xhci_hcd/unbind" "$dev" || return 1
  sleep "${SSD_USB_XHCI_UNBIND_SEC:-5}"
  ssd_sysfs_write "/sys/bus/pci/drivers/xhci_hcd/bind" "$dev" || return 1
  sleep "${SSD_USB_XHCI_BIND_SEC:-12}"
  command -v udevadm >/dev/null 2>&1 && _ssd_alive_root udevadm settle --timeout=20 2>/dev/null || sleep 5
  ssd_find_usb_sysfs >/dev/null 2>&1 || ssd_block_present
}

ssd_usb_reboot_once() {
  [[ "${SSD_USB_RESET_REBOOT:-false}" == "true" ]] || return 1
  local now ts stamp="$SSD_USB_REBOOT_STAMP_FILE"
  now="$(date +%s)"
  if [[ -f "$stamp" ]]; then
    ts="$(tr -d '[:space:]' <"$stamp" 2>/dev/null || true)"
    ts="${ts:-0}"
    if [[ "$ts" =~ ^[0-9]+$ ]] && (( now - ts < SSD_USB_RESET_WINDOW_SEC * 2 )); then
      echo "[ssd-alive] reboot zaten denendi (${SSD_USB_RESET_WINDOW_SEC}*2s) — atlaniyor" >&2
      return 1
    fi
  fi
  _ssd_alive_root mkdir -p "$(dirname "$stamp")" 2>/dev/null || true
  if [[ "$(id -u)" -eq 0 ]]; then
    printf '%s\n' "$now" >"$stamp"
  else
    printf '%s\n' "$now" | sudo tee "$stamp" >/dev/null
  fi
  echo "[ssd-alive] SSD_USB_RESET_REBOOT=true — reboot (tek seferlik pencere)" >&2
  _ssd_alive_root systemctl reboot || true
}

_ssd_usb_soft_reset_body() {
  SSD_USB_RESET_COUNTED=0

  ssd_usb_disable_autosuspend

  if mountpoint -q "$SSD_MOUNT" 2>/dev/null && ! ssd_mount_healthy; then
    echo "[ssd-alive] hung mount — umount -l $SSD_MOUNT" >&2
    _ssd_alive_root umount -l "$SSD_MOUNT" 2>/dev/null || true
  fi

  if ssd_find_usb_sysfs >/dev/null 2>&1 && ! ssd_mount_healthy; then
    ssd_usb_storage_rebind || true
    ssd_try_remount || true
    ssd_mount_healthy && return 0
  fi

  if ssd_usb_bus_dropout || { [[ "${SSD_USB_CYCLE_ON_HANG:-true}" == "true" ]] && ! ssd_mount_healthy; }; then
    ssd_usb_port_disable_cycle || true
  fi

  if ssd_usb_bus_dropout; then
    ssd_xhci_rebind || true
  fi

  if [[ "$SSD_USB_AUTHORIZED_RESET" == "true" ]]; then
    if ssd_usb_reset_rate_limited; then
      echo "[ssd-alive] USB authorized rate-limit (${SSD_USB_RESET_MAX}/${SSD_USB_RESET_WINDOW_SEC}s)" >&2
      ssd_usb_reboot_once || true
      return 1
    fi
    local sys
    sys="$(ssd_find_usb_sysfs 2>/dev/null || true)"
    if [[ -n "$sys" && -f "${sys}/authorized" ]]; then
      ssd_usb_reset_record_once
      echo "[ssd-alive] USB authorized cycle: $sys" >&2
      ssd_sysfs_write "${sys}/authorized" 0 || true
      sleep 2
      ssd_sysfs_write "${sys}/authorized" 1 || true
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
    if [[ -n "$disk" && "$disk" == /dev/* ]]; then
      _ssd_alive_root partprobe "$(echo "$disk" | sed -E 's/p?[0-9]+$//')" 2>/dev/null || true
    fi
  fi
  ssd_try_remount || true
  if ssd_mount_healthy; then
    return 0
  fi
  if ssd_usb_bus_dropout && ssd_usb_reset_rate_limited; then
    ssd_usb_reboot_once || true
  fi
  return 1
}

# Merdiven: LPM off → umount hung → usb-storage rebind → USB3 port tarama → xhci opt-in
ssd_usb_soft_reset() {
  local lockdir="${SSD_USB_RESET_LOCK_DIR:-/run/pi-gateway/ssd-usb-reset.lock}"
  local lock_owned=0 rc mtime now parent waited=0
  local max_wait="${SSD_USB_RESET_LOCK_WAIT_SEC:-45}"
  parent="$(dirname "$lockdir")"
  # sudo yok: Mac validate sudo prompt olmasin. Pi health root.
  if [[ "$(id -u)" -eq 0 ]]; then
    mkdir -p "$parent" 2>/dev/null || true
  fi
  [[ "$max_wait" =~ ^[0-9]+$ ]] || max_wait=45
  if [[ -d "$parent" && -w "$parent" ]]; then
    while true; do
      if [[ -d "$lockdir" ]]; then
        mtime="$(stat -f %m "$lockdir" 2>/dev/null || stat -c %Y "$lockdir" 2>/dev/null || echo 0)"
        now="$(date +%s)"
        if [[ "$mtime" =~ ^[0-9]+$ ]] && (( now - mtime > 400 )); then
          echo "[ssd-alive] stale reset lock — siliniyor" >&2
          rmdir "$lockdir" 2>/dev/null || true
        fi
      fi
      if mkdir "$lockdir" 2>/dev/null; then
        lock_owned=1
        break
      fi
      if [[ -d "$lockdir" ]]; then
        if (( waited >= max_wait )); then
          echo "[ssd-alive] soft-reset kilit bekleme doldu (${max_wait}s)" >&2
          return 1
        fi
        sleep 1
        waited=$((waited + 1))
        continue
      fi
      break
    done
  fi
  _ssd_usb_soft_reset_body
  rc=$?
  if [[ "$lock_owned" == "1" ]]; then
    rmdir "$lockdir" 2>/dev/null || true
  fi
  return "$rc"
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
    grep -q "usb-storage.quirks=${SSD_USB_VID}:${SSD_USB_PID}:u" "$f" 2>/dev/null || continue
    grep -q "usbcore.quirks=${SSD_USB_VID}:${SSD_USB_PID}:k" "$f" 2>/dev/null || continue
    grep -q 'usbcore.autosuspend=-1' "$f" 2>/dev/null || continue
    return 0
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
