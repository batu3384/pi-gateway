#!/usr/bin/env bash
# Uzaktan erisim teşhisi (Tailscale + *.home + TLS)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

LAN_DOMAIN="${LAN_DOMAIN:-home}"
PI_IP="${PI_STATIC_IP:-192.168.1.112}"
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
else
  fail "Tailscale bagli degil"
fi

if dig +short @"${PI_IP}" "gateway.${LAN_DOMAIN}" A 2>/dev/null | grep -qx "${PI_IP}"; then
  pass "AdGuard rewrite gateway.${LAN_DOMAIN} -> ${PI_IP}"
else
  warn "gateway.${LAN_DOMAIN} rewrite beklenen ${PI_IP} degil"
fi

if curl -sk -o /dev/null -w "%{http_code}" --max-time 5 \
  -H "Host: gateway.${LAN_DOMAIN}" "https://127.0.0.1/" 2>/dev/null | grep -qE '^(401|200|302)$'; then
  pass "Caddy gateway.${LAN_DOMAIN} yanit veriyor (LAN)"
else
  fail "Caddy gateway.${LAN_DOMAIN} yanit vermiyor"
fi

if [[ -n "${TS_DNS:-}" ]]; then
  code="$(curl -sk -o /dev/null -w "%{http_code}" --max-time 8 \
    -H "Host: ${TS_DNS}" "https://127.0.0.1/" 2>/dev/null || echo 000)"
  if [[ "$code" =~ ^(200|401|302)$ ]]; then
    pass "Tailscale panel URL yanit: https://${TS_DNS}/ -> ${code}"
  else
    fail "Tailscale panel URL yanit vermiyor (${code})"
  fi
fi

echo ""
echo "=== Ozet ==="
echo "Telegram *.${LAN_DOMAIN} linkleri uzaktan icin:"
echo "  1) Tailscale split DNS: ${LAN_DOMAIN} -> Pi Tailscale IP"
echo "  2) Subnet route onayi (192.168.1.0/24)"
echo "  3) VEYA tailscale serve URL kullan (mkcert telefonda guvenilmez)"
echo "Sonuc: ${ok} OK, ${fail} FAIL"
[[ "$fail" -eq 0 ]]
