#!/usr/bin/env bash
# AGH :53 olunca dur; USB/docker hang'de host DoT proxy baslat.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT="pi-gateway-dns-fallback.service"
log() { echo "[dns-host-fallback] $*"; }

if [[ -f "${SCRIPT_DIR}/../lib/env-file.sh" ]]; then
  # shellcheck source=../lib/env-file.sh
  source "${SCRIPT_DIR}/../lib/env-file.sh"
  read_remote_dotenv || true
fi

if [[ "${DNS_HOST_FALLBACK:-true}" != "true" ]]; then
  log "DNS_HOST_FALLBACK=false — atlandi"
  exit 0
fi

run_sys() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo -n "$@"
  else
    sudo "$@"
  fi
}

agh_rewrite_ok() {
  local ip="${PI_STATIC_IP:-127.0.0.1}"
  local domain="${LAN_DOMAIN:-home}"
  timeout 2 dig +time=1 +tries=1 +short @"$ip" "gateway.${domain}" A 2>/dev/null \
    | grep -qx "$ip"
}

cmd_stop() {
  run_sys systemctl stop "$UNIT" 2>/dev/null || true
  run_sys systemctl reset-failed "$UNIT" 2>/dev/null || true
}

cmd_start() {
  if agh_rewrite_ok; then
    cmd_stop
    log "AGH :53 ayakta"
    return 0
  fi
  if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
    return 0
  fi
  if ! run_sys systemctl start "$UNIT"; then
    log "WARN unit start basarisiz"
    return 1
  fi
  log "basladi (AGH yok)"
}

cmd_ensure() {
  if agh_rewrite_ok; then
    cmd_stop
    return 0
  fi
  cmd_start
}

case "${1:-ensure}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  ensure) cmd_ensure ;;
  --self-check)
    grep -q 'dns-dot-proxy.py' "$0" || exit 1
    [[ -f "${SCRIPT_DIR}/../lib/dns-dot-proxy.py" ]] || exit 1
    python3 "${SCRIPT_DIR}/../lib/dns-dot-proxy.py" --self-check
    ;;
  *)
    log "HATA: kullanim: start|stop|ensure|--self-check"
    exit 2
    ;;
esac
