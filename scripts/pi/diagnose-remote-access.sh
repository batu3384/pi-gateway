#!/usr/bin/env bash
# Uzaktan erisim teşhisi (Tailscale + *.home + TLS)
# HTTPS probe: Host header yetmez — TLS SNI icin --resolve kullan
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
LAN_DOMAIN="${LAN_DOMAIN:-home}"
PI_IP="${PI_STATIC_IP:-127.0.0.1}"
ok=0 fail=0
pass() { echo "[OK] $*"; ok=$((ok + 1)); }
fail() { echo "[FAIL] $*"; fail=$((fail + 1)); }
warn() { echo "[WARN] $*"; }
echo "=== Pi Gateway uzaktan erisim ==="
if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
  TS_DNS="$(tailscale status --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))")"
  ROUTES="$(tailscale status --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
p=d.get('Prefs',{}).get('AdvertiseRoutes')
if p:
    print(p)
else:
    print(d.get('Self',{}).get('PrimaryRoutes') or [])
")"
  pass "Tailscale bagli — ${TS_IP} (${TS_DNS})"
  if [[ "$ROUTES" == "[]" || "$ROUTES" == "None" || -z "$ROUTES" ]]; then
    fail "Subnet route reklam edilmiyor — telefon 192.168.1.x erisemez"
    echo "       Cozum: bash scripts/pi/setup-tailscale-remote.sh + admin onayi"
  else
    pass "Subnet route: ${ROUTES} (admin onayi gerekebilir)"
  fi
  if tailscale serve status 2>/dev/null | grep -qE "443|https"; then
    pass "tailscale serve aktif (guvenilir HTTPS)"
  else
    fail "tailscale serve yok — telefon mkcert *.home guvenmez"
    echo "       Cozum: bash scripts/pi/setup-tailscale-serve.sh"
  fi
  if [[ -n "$TS_IP" ]]; then
    code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${TS_IP}/" 2>/dev/null || echo 000)"
    if [[ "$code" =~ ^(200|401|302)$ ]]; then
      pass "Tailscale IP HTTP: http://${TS_IP}/ -> ${code}"
    else
      fail "Tailscale IP HTTP yanit vermiyor (${code})"
    fi
  fi
else
  fail "Tailscale bagli degil"
fi
if dig +short @"${PI_IP}" "gateway.${LAN_DOMAIN}" A 2>/dev/null | grep -qx "${PI_IP}"; then
  pass "AdGuard rewrite gateway.${LAN_DOMAIN} -> ${PI_IP}"
else
  warn "gateway.${LAN_DOMAIN} rewrite beklenen ${PI_IP} degil"
fi
# SNI zorunlu: -H Host yetmez (TLS alert / false FAIL)
# Caddy LAN IP bind — 127.0.0.1:443 yok
gw_code="$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 \
  --resolve "gateway.${LAN_DOMAIN}:443:${PI_IP}" \
  "https://gateway.${LAN_DOMAIN}/" 2>/dev/null || echo 000)"
if [[ "$gw_code" =~ ^(401|200|302)$ ]]; then
  pass "Caddy gateway.${LAN_DOMAIN} HTTPS (SNI) -> ${gw_code}"
else
  fail "Caddy gateway.${LAN_DOMAIN} HTTPS yanit vermiyor (${gw_code})"
fi
if [[ -n "${TS_DNS:-}" && -n "${TS_IP:-}" ]]; then
  # MagicDNS Pi'de cozulmeyebilir — Serve'i TS IP uzerinden SNI ile dene
  code="$(curl -sk -o /dev/null -w "%{http_code}" --max-time 8 \
    --resolve "${TS_DNS}:443:${TS_IP}" \
    "https://${TS_DNS}/" 2>/dev/null || echo 000)"
  if [[ "$code" =~ ^(200|401|302)$ ]]; then
    pass "Tailscale Serve URL: https://${TS_DNS}/ -> ${code}"
  else
    fail "Tailscale Serve URL yanit vermiyor (${code})"
  fi
fi
echo ""
echo "=== Ozet ==="
echo "Telefon: http://\${TS_IP}/ veya Serve https://\${TS_DNS}/ (Safari; Telegram ici bazen kirar)"
echo "LAN: https://gateway.${LAN_DOMAIN} (Pi DNS + mkcert trust)"
echo "USB SSD: dogrudan Pi USB3; guc yetmezse powered High-Speed (480M+) hub — Full-Speed 12M hub kullanma"
echo "Sonuc: ${ok} OK, ${fail} FAIL"
[[ "$fail" -eq 0 ]]
