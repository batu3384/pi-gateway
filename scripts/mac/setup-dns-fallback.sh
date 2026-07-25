#!/usr/bin/env bash
# macOS + router: Pi birincil DNS, yedek DNS (Pi kapaliyken internet devam eder)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_DNS="${PI_STATIC_IP:-}"
FALLBACK_DNS="${ROUTER_DNS_SECONDARY:-1.1.1.1}"
PI_INTERFACE="${PI_INTERFACE:-eth0}"

log() { echo "[dns-fallback] $*"; }

[[ "$(uname)" == "Darwin" ]] || { log "Sadece macOS"; exit 1; }
[[ -n "$PI_DNS" ]] || die "PI_STATIC_IP gerekli (.env)"

mac_service() {
  local iface="$1"
  networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while read -r svc; do
    [[ "$svc" == *"*"* ]] && continue
    port="$(networksetup -listnetworkserviceorder 2>/dev/null | grep -A1 "$svc" | grep "Device:" | sed 's/.*Device: //;s/)//')"
    [[ "$port" == "$iface" ]] && { echo "$svc"; return 0; }
  done
  networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | grep -iE 'ethernet|wi-fi' | head -1
}

SERVICE="$(mac_service "$PI_INTERFACE" || true)"
[[ -n "$SERVICE" ]] || die "Aktif ag servisi bulunamadi"

log "Mac DNS: $SERVICE -> $PI_DNS (birincil), $FALLBACK_DNS (yedek)"
if sudo -n true 2>/dev/null; then
  sudo networksetup -setdnsservers "$SERVICE" "$PI_DNS" "$FALLBACK_DNS"
else
  osascript -e "do shell script \"networksetup -setdnsservers '$SERVICE' '$PI_DNS' '$FALLBACK_DNS'\" with administrator privileges"
fi

sudo dscacheutil -flushcache 2>/dev/null || true
sudo killall -HUP mDNSResponder 2>/dev/null || true

log ""
log "=== Router (evdeki tum cihazlar icin) ==="
log "Birincil DNS : $PI_DNS"
log "Ikincil DNS  : $FALLBACK_DNS"
log "Pi kapaliyken ikincil DNS ile internet calisir (*.home ve reklam engeli durur)."
log ""

if dig +time=3 +tries=1 @"$PI_DNS" google.com A +short >/dev/null 2>&1; then
  log "Test OK: Pi DNS yanit veriyor"
else
  log "UYARI: Pi DNS su an yanit vermiyor — yedek DNS sayesinde internet calisir"
fi
