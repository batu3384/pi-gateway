#!/usr/bin/env bash
# ZTE H3600P WiFi/DHCP performans denetimi (read-only API + dhcp sniff).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[modem-audit] HATA: .env" >&2; exit 1; }

log() { echo "[modem-audit] $*"; }
fail=0
note_fail() { log "FAIL $1"; fail=1; }

PI_IP="${PI_STATIC_IP:-}"

if [[ "${1:-}" == "--self-check" ]]; then
  [[ -f "$SCRIPT_DIR/../lib/zte-h3600p.py" ]] || exit 1
  grep -qF 'MODEM_ALLOW_HTTP="${MODEM_ALLOW_HTTP:-false}" \' "$0" || exit 1
  grep -qF '  if ! sudo' "$0" || exit 1
  log "self-check OK"
  exit 0
fi

if [[ "${MODEM_INVENTORY_ENABLED:-false}" != "true" ]]; then
  log "MODEM_INVENTORY_ENABLED=false — sadece dhcp sniff"
else
  # ZTE permits one admin session; sync owns login, fetch, and logout.
  if ! sudo MODEM_CREDENTIAL_FILE="${MODEM_CREDENTIAL_FILE:-/etc/pi-gateway/modem-inventory.env}" \
    MODEM_URL="${MODEM_URL:-http://192.168.1.1}" \
    MODEM_ALLOW_HTTP="${MODEM_ALLOW_HTTP:-false}" \
    MODEM_INVENTORY_ENABLED=true REMOTE_DIR="$REMOTE_DIR" \
    bash "$SCRIPT_DIR/sync-modem-inventory.sh"; then
    note_fail "inventory-sync"
  fi
fi

echo "=== DHCP sniff ==="
# shellcheck source=../lib/dhcp-dns-offer.sh
source "$SCRIPT_DIR/../lib/dhcp-dns-offer.sh"
GATEWAY_IP="${GATEWAY_IP:-${MODEM_GATEWAY:-192.168.1.1}}"
dhcp_rc=0
check_dhcp_dns_offer "${PI_IP:-127.0.0.1}" "$GATEWAY_IP" "${PI_INTERFACE:-eth0}" || dhcp_rc=$?
if [[ "$dhcp_rc" -eq 0 ]]; then
  log "DHCP DNS OK"
elif [[ "$dhcp_rc" -eq 3 ]]; then
  log "WARN: DHCP Pi+modem fallback (ZTE DNS2 beklenen)"
else
  note_fail "dhcp-sniff"
fi

echo "=== Pi DNS ==="
[[ -n "$PI_IP" ]] && dig +time=2 +tries=1 @"$PI_IP" google.com A +short | head -1 | grep -q '.' \
  || note_fail "pi-dns"

[[ "$fail" -eq 0 ]] && log "Tamam" && exit 0
log "Sonuc: FAIL"
exit 1
