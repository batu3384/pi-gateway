#!/usr/bin/env bash
# Reboot sonrasi kurtarma dogrulama (Pi uzerinde calistirilir)
# Kullanim:
#   reboot-smoke.sh pre   — durum kaydet + reboot
#   reboot-smoke.sh post  — reboot sonrasi dogrula (varsayilan)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
STATE_DIR="/var/lib/pi-gateway/reboot-smoke"
MODE="${1:-post}"

log() { echo "[reboot-smoke] $*"; }

save_pre_state() {
  sudo mkdir -p "$STATE_DIR"
  {
    echo "started=$(date -Iseconds)"
    echo "root_rw=$(findmnt -n -o OPTIONS / | tr ',' '\n' | grep -qx ro && echo no || echo yes)"
    systemctl is-active docker 2>/dev/null || true
    systemctl show pi-gateway-recover-ro.service -p Result --value 2>/dev/null || true
  } | sudo tee "$STATE_DIR/pre-state.txt" >/dev/null
}

wait_for_recover() {
  local waited=0
  while (( waited < 360 )); do
    if systemctl is-failed pi-gateway-recover-ro.service 2>/dev/null | grep -q failed; then
      log "HATA: pi-gateway-recover-ro failed"
      systemctl status pi-gateway-recover-ro.service --no-pager || true
      return 1
    fi
    local result
    result="$(systemctl show pi-gateway-recover-ro.service -p Result --value 2>/dev/null || true)"
    if [[ "$result" == "success" ]]; then
      log "recover-ro Result=success (${waited}s)"
      return 0
    fi
    sleep 10
    waited=$((waited + 10))
  done
  log "HATA: recover-ro 360s icinde success olmadi"
  systemctl status pi-gateway-recover-ro.service --no-pager || true
  return 1
}

verify_post() {
  log "Reboot sonrasi dogrulama basliyor..."
  sleep 30
  wait_for_recover
  run_check_root_rw() {
    ! findmnt -n -o OPTIONS / | tr ',' '\n' | grep -qx ro
  }
  if run_check_root_rw; then
    log "OK: root read-write"
  else
    log "HATA: root hala read-only"
    exit 1
  fi
  smoke_script="${REMOTE_DIR}/scripts/pi/smoke-test.sh"
  REMOTE_DIR="$REMOTE_DIR" bash "$smoke_script"
  log "Reboot smoke tamamlandi"
}

case "$MODE" in
  pre)
    save_pre_state
    log "5 saniye sonra reboot..."
    sleep 5
    sudo reboot
    ;;
  post)
    verify_post
    ;;
  *)
    log "Kullanim: $0 [pre|post]"
    exit 1
    ;;
esac
