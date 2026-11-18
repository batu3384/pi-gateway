#!/usr/bin/env bash
# macOS: *.home sorgularini Pi DNS'e yonlendir
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env
PI_DNS="${PI_STATIC_IP:-}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
RESOLVER_DIR="/etc/resolver"
RESOLVER_FILE="${RESOLVER_DIR}/${LAN_DOMAIN}"
log() { echo "[mac-dns] $*"; }
[[ "$(uname)" == "Darwin" ]] || { log "Sadece macOS"; exit 1; }
[[ -n "$PI_DNS" ]] || { log "HATA: PI_STATIC_IP gerekli (.env)"; exit 1; }
[[ "$LAN_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || { log "HATA: gecersiz LAN_DOMAIN: $LAN_DOMAIN"; exit 1; }
python3 -c 'import ipaddress, sys; ip = ipaddress.ip_address(sys.argv[1]); raise SystemExit(0 if ip.version == 4 else 1)' "$PI_DNS" \
  || { log "HATA: gecersiz IPv4 PI_STATIC_IP: $PI_DNS"; exit 1; }
if [[ -f "$RESOLVER_FILE" ]] && grep -Fxq "nameserver $PI_DNS" "$RESOLVER_FILE" 2>/dev/null; then
  log "Zaten ayarli: $RESOLVER_FILE -> $PI_DNS"
else
  log "Resolver olusturuluyor: $RESOLVER_FILE"
  if sudo -n true 2>/dev/null; then
    sudo mkdir -p "$RESOLVER_DIR"
    printf 'nameserver %s\n' "$PI_DNS" | sudo tee "$RESOLVER_FILE" >/dev/null
    sudo chmod 644 "$RESOLVER_FILE"
  else
    osascript -e "do shell script \"mkdir -p ${RESOLVER_DIR} && printf 'nameserver ${PI_DNS}\\\\n' > ${RESOLVER_FILE} && chmod 644 ${RESOLVER_FILE}\" with administrator privileges" || {
      log "HATA: sudo veya yonetici izni gerekli"
      exit 1
    }
  fi
fi
sudo -n dscacheutil -flushcache 2>/dev/null || true
sudo -n killall -HUP mDNSResponder 2>/dev/null || true
log "Test: dig gateway.${LAN_DOMAIN} +short"
result="$(dig +time=3 +tries=1 "gateway.${LAN_DOMAIN}" +short 2>/dev/null | head -1 || true)"
if [[ "$result" == "$PI_DNS" ]]; then
  log "Tamam — gateway.${LAN_DOMAIN} -> $result"
else
  log "UYARI: gateway.${LAN_DOMAIN} beklenen $PI_DNS, alinan: ${result:-bos}"
  log "Sistem DNS'i Pi'ye yonlendiginden emin olun (Ayarlar > Ag > DNS)"
  exit 1
fi
