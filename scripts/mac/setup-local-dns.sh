#!/usr/bin/env bash
# macOS: *.home sorgularini Pi DNS'e yonlendir
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_project_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
PI_DNS="${PI_STATIC_IP:-}"
RESOLVER_DIR="/etc/resolver"
RESOLVER_FILE="${RESOLVER_DIR}/home"
log() { echo "[mac-dns] $*"; }
[[ "$(uname)" == "Darwin" ]] || { log "Sadece macOS"; exit 1; }
[[ -n "$PI_DNS" ]] || { log "HATA: PI_STATIC_IP gerekli (.env)"; exit 1; }
if [[ -f "$RESOLVER_FILE" ]] && grep -q "$PI_DNS" "$RESOLVER_FILE" 2>/dev/null; then
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
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder 2>/dev/null || true
log "Test: dig gateway.home +short"
result="$(dig +time=3 +tries=1 gateway.home +short 2>/dev/null | head -1 || true)"
if [[ "$result" == "$PI_DNS" ]]; then
  log "Tamam — gateway.home -> $result"
else
  log "UYARI: gateway.home beklenen $PI_DNS, alinan: ${result:-bos}"
  log "Sistem DNS'i Pi'ye yonlendiginden emin olun (Ayarlar > Ag > DNS)"
  exit 1
fi
